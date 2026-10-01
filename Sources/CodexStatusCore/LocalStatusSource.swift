import Foundation
import ProcessInspection

private final class WriterCollector {
    var records: [WriterRecord] = []
}

private func receiveWriter(_ id: UnsafePointer<CChar>?, _ pid: Int32, _ started: Double,
                           _ context: UnsafeMutableRawPointer?) {
    guard let id, let context, let threadID = normalizedID(String(cString: id)) else { return }
    let collector = Unmanaged<WriterCollector>.fromOpaque(context).takeUnretainedValue()
    collector.records.append(WriterRecord(threadID: threadID, pid: pid,
                                         processStartedAt: Date(timeIntervalSince1970: started)))
}

public actor LocalStatusSource {
    private let home: URL
    private let reader = RolloutReader()
    private var paths: [String: [URL]] = [:]
    private var archivedPaths: [String: [URL]] = [:]
    private var lastScan = Date.distantPast
    private let idPattern = try! NSRegularExpression(
        pattern: #"^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?\.jsonl$"#
    )

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
    }

    public func sample(appPID: Int32?, appBundle: URL?) -> StatusSnapshot {
        guard let appPID else { return .unavailable("Codex 未运行", appIsRunning: false) }
        guard let appBundle else { return .unavailable("无法确认 Codex 应用位置", appIsRunning: true) }
        let now = Date()
        let collector = WriterCollector()
        var engines: Int32 = 0
        let lockDirectory = home.appendingPathComponent("thread-writer-locks").path
        let bundlePath = appBundle.resolvingSymlinksInPath().standardizedFileURL.path
        let inspected = lockDirectory.withCString { locks in
            bundlePath.withCString { bundle in
                cs_inspect_writers(appPID, bundle, locks, receiveWriter,
                                   Unmanaged.passUnretained(collector).toOpaque(), &engines)
            }
        }
        guard inspected == 0 else {
            return .unavailable("无法完整读取本机进程状态", appIsRunning: true)
        }
        guard engines > 0 else {
            return .unavailable("尚未连接到本机 Codex 引擎", appIsRunning: true)
        }
        return assemble(now: now, writers: collector.records)
    }

    // Internal entry point makes all filesystem behavior testable with synthetic data.
    func assemble(now: Date, writers: [WriterRecord]) -> StatusSnapshot {
        var notices: [String] = []
        var unread: UnreadState?
        do {
            unread = try UnreadState.decode(readBounded(home.appendingPathComponent(".codex-global-state.json")))
        } catch {
            notices.append((error as? SourceError)?.localizedDescription ?? "无法读取 Codex 未读标记")
        }
        let index: [String: Data]
        do { index = try readIndex() }
        catch { return .unavailable("无法读取会话索引", appIsRunning: true) }
        do {
            if now.timeIntervalSince(lastScan) >= 5 {
                try scanPaths()
                lastScan = now
            }
        } catch { return .unavailable("无法完整读取会话目录", appIsRunning: true) }
        let grouped = Dictionary(grouping: writers, by: \.threadID)
        let unreadIDs = unread?.threadIDs ?? []
        let targets = Set(grouped.keys).union(unreadIDs)
        var sessions: [SessionStatus] = []
        var runningKnown = true
        var unreadKnown = unread != nil
        var retainedPaths: Set<URL> = []
        func recordUnknown(_ id: String) {
            if grouped[id] != nil, index[id] != nil { runningKnown = false }
            if unreadIDs.contains(id) { unreadKnown = false }
            sessions.append(SessionStatus(id: id, title: "状态未知", phase: .unknown,
                                          isUnread: unreadIDs.contains(id), updatedAt: nil))
        }
        for id in targets.sorted() {
            guard let files = paths[id], !files.isEmpty else {
                if let archived = archivedPaths[id] {
                    do {
                        let headers = try archived.map { try reader.header(at: $0) }
                        guard headers.allSatisfy({ $0.id == id && $0.source != .unknown }) else {
                            throw SourceError.malformed
                        }
                        continue
                    } catch {
                        recordUnknown(id)
                        continue
                    }
                }
                // Codex also holds internal shadow-thread locks without visible rollouts.
                if index[id] != nil || unreadIDs.contains(id) { recordUnknown(id) }
                continue
            }
            if index[id] == nil && !unreadIDs.contains(id) { continue }
            retainedPaths.formUnion(files)
            do {
                let readings = try files.map { try reader.read($0) }
                guard readings.allSatisfy({ $0.header.id == id && $0.header.source != .unknown }) else {
                    throw SourceError.malformed
                }
                let main = readings.filter { $0.header.isPrimaryDesktop }
                if main.isEmpty { continue }
                guard let indexEntry = index[id] else { recordUnknown(id); continue }
                guard !main.contains(where: { $0.lifecycle.phase == .unknown }) else {
                    throw SourceError.malformed
                }
                guard let reading = main.max(by: {
                    ($0.lifecycle.updatedAt ?? .distantPast) < ($1.lifecycle.updatedAt ?? .distantPast)
                }) else { continue }
                let phase = reading.lifecycle.phase(with: grouped[id] ?? [])
                if phase == .unknown {
                    if grouped[id] != nil { runningKnown = false }
                    if unreadIDs.contains(id) { unreadKnown = false }
                }
                sessions.append(SessionStatus(id: id, title: title(from: indexEntry),
                                              phase: phase, isUnread: unreadIDs.contains(id),
                                              updatedAt: reading.lifecycle.updatedAt,
                                              phaseSince: phase == .running || phase == .waitingForInput
                                                  ? reading.lifecycle.startedAt : nil,
                                              project: reading.header.project))
            } catch {
                recordUnknown(id)
            }
        }
        reader.prune(keeping: retainedPaths)
        if !runningKnown || (unread != nil && !unreadKnown) {
            notices.append("部分轮次状态无法确认")
        }
        sessions.sort {
            if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            return $0.id < $1.id
        }
        return StatusSnapshot(
            sampledAt: now, sessions: sessions,
            runningCount: runningKnown ? sessions.filter { $0.phase == .running }.count : nil,
            completedUnreadCount: unreadKnown ? sessions.filter { $0.phase == .completed && $0.isUnread }.count : nil,
            notice: notices.isEmpty ? nil : notices.joined(separator: "；"),
            appIsRunning: true, inspectedWriterCount: grouped.count
        )
    }

    private func readBounded(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 8 * 1024 * 1024 else { throw SourceError.oversized }
        return data
    }

    private func readIndex() throws -> [String: Data] {
        struct Entry: Decodable {
            let id: String
        }
        let data = try readBounded(home.appendingPathComponent("session_index.jsonl"))
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if data.last != 10, !lines.isEmpty { lines.removeLast() }
        let decoder = JSONDecoder()
        var entries: [String: Data] = [:]
        for line in lines where !line.isEmpty {
            let data = Data(line)
            let entry = try decoder.decode(Entry.self, from: data)
            guard let id = normalizedID(entry.id) else { throw SourceError.malformed }
            entries[id] = data
        }
        return entries
    }

    private func title(from data: Data) -> String {
        struct Entry: Decodable { let thread_name: String }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return "未命名会话" }
        let name = entry.thread_name.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名会话" : name
    }

    private func scanPaths() throws {
        var found: [String: [URL]] = [:]
        for url in try rolloutFiles(in: home.appendingPathComponent("sessions"), required: true) {
            if let id = filenameID(url) { found[id, default: []].append(url) }
        }
        var archived: [String: [URL]] = [:]
        for url in try rolloutFiles(in: home.appendingPathComponent("archived_sessions"), required: false) {
            if let id = filenameID(url) { archived[id, default: []].append(url) }
        }
        paths = found
        archivedPaths = archived
    }

    private func rolloutFiles(in directory: URL, required: Bool) throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else {
            if required { throw SourceError.unreadable }
            return []
        }
        var failed = false
        guard let enumerator = manager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in failed = true; return false }
        ) else { throw SourceError.unreadable }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true, url.pathExtension == "jsonl" { files.append(url) }
        }
        if failed { throw SourceError.unreadable }
        return files
    }

    private func filenameID(_ url: URL) -> String? {
        let name = url.lastPathComponent
        guard let match = idPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return nil }
        return normalizedID(String(name[range]))
    }
}
