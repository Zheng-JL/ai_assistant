import Foundation

struct RolloutHeader: Decodable, Sendable {
    enum Source: Sendable { case primaryDesktop, excluded, unknown }

    let id: String
    let source: Source
    let project: String?
    var isPrimaryDesktop: Bool { source == .primaryDesktop }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        guard try root.decode(String.self, forKey: .type) == "session_meta" else {
            throw SourceError.malformed
        }
        let payload = try root.nestedContainer(keyedBy: Keys.self, forKey: .payload)
        let rawID = try payload.decode(String.self, forKey: .id)
        guard let id = normalizedID(rawID) else { throw SourceError.malformed }
        self.id = id
        project = projectName(fromPath: try payload.decodeIfPresent(String.self, forKey: .cwd))
        let originator = try payload.decodeIfPresent(String.self, forKey: .originator)
        if let name = try? payload.decode(String.self, forKey: .source) {
            if originator == "Codex Desktop", name == "vscode" {
                source = .primaryDesktop
            } else {
                source = name == "cli" ? .excluded : .unknown
            }
        } else if let nested = try? payload.nestedContainer(keyedBy: Keys.self, forKey: .source),
                  nested.contains(.subagent), (try? nested.decodeNil(forKey: .subagent)) == false {
            source = .excluded
        } else {
            source = .unknown
        }
    }

    enum Keys: String, CodingKey { case type, payload, id, originator, source, subagent, cwd }
}

struct Lifecycle: Sendable, Equatable {
    var phase: SessionPhase = .unknown
    var turnID: String?
    var startedAt: Date?
    var updatedAt: Date?
    var pendingInputCalls: Set<String> = []

    mutating func invalidate() { self = Lifecycle() }

    mutating func apply(_ record: StatusRecord) {
        if record.type == "event_msg" {
            switch record.payload.type {
            case "task_started":
                guard let incoming = record.payload.turnID, !incoming.isEmpty,
                      let timestamp = eventDate(record.timestamp) else { invalidate(); return }
                phase = .running
                turnID = incoming
                startedAt = timestamp
                updatedAt = timestamp
                pendingInputCalls.removeAll()
            case "task_complete", "turn_aborted":
                guard let incoming = record.payload.turnID, !incoming.isEmpty,
                      let timestamp = eventDate(record.timestamp) else { invalidate(); return }
                if let current = turnID, current != incoming { return }
                phase = record.payload.type == "task_complete" ? .completed : .interrupted
                turnID = incoming
                updatedAt = timestamp
                pendingInputCalls.removeAll()
            case "error":
                // An error event alone does not establish whether a retry follows.
                invalidate()
                updatedAt = eventDate(record.timestamp)
            default: break
            }
        } else if record.type == "response_item", phase == .running || phase == .waitingForInput {
            if record.payload.type == "function_call" {
                guard let name = record.payload.name, !name.isEmpty,
                      let id = record.payload.callID, !id.isEmpty else { invalidate(); return }
                if name == "request_user_input" || name.hasSuffix(".request_user_input") {
                    pendingInputCalls.insert(id)
                    phase = .waitingForInput
                }
            } else if record.payload.type == "function_call_output" {
                guard let id = record.payload.callID, !id.isEmpty else { invalidate(); return }
                pendingInputCalls.remove(id)
                phase = pendingInputCalls.isEmpty ? .running : .waitingForInput
            }
        }
    }

    func phase(with writers: [WriterRecord]) -> SessionPhase {
        guard phase == .running || phase == .waitingForInput else { return phase }
        guard let startedAt,
              writers.contains(where: { $0.processStartedAt <= startedAt }) else { return .unknown }
        return phase
    }
}

// Intentionally excludes message content, command arguments, outputs, and instructions.
struct StatusRecord: Decodable {
    let type: String
    let timestamp: String?
    let payload: Payload

    struct Payload: Decodable {
        let type: String?
        let turnID: String?
        let name: String?
        let callID: String?
        enum CodingKeys: String, CodingKey {
            case type, name
            case turnID = "turn_id"
            case callID = "call_id"
        }
    }
}

private struct RecordKind: Decodable {
    let isTracked: Bool

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        let type = try root.decode(String.self, forKey: .type)
        guard type == "event_msg" || type == "response_item" else { isTracked = false; return }
        let payload = try root.nestedContainer(keyedBy: Keys.self, forKey: .payload)
        let subtype = try payload.decode(String.self, forKey: .type)
        isTracked = type == "event_msg"
            ? ["task_started", "task_complete", "turn_aborted", "error"].contains(subtype)
            : ["function_call", "function_call_output"].contains(subtype)
    }

    enum Keys: String, CodingKey { case type, payload }
}

final class RolloutReader {
    struct Reading {
        let header: RolloutHeader
        let lifecycle: Lifecycle
    }
    private struct Cached {
        let size: UInt64
        let modified: Date
        let fileNumber: UInt64
        let reading: Reading
    }
    private var cache: [URL: Cached] = [:]
    private let decoder = JSONDecoder()
    private let maxBytes = 8 * 1024 * 1024

    func prune(keeping paths: Set<URL>) {
        cache = cache.filter { paths.contains($0.key) }
    }

    func header(at url: URL) throws -> RolloutHeader {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try readHeader(file)
    }

    func read(_ url: URL) throws -> Reading {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? UInt64,
              let modified = attributes[.modificationDate] as? Date,
              let fileNumber = attributes[.systemFileNumber] as? UInt64 else { throw SourceError.unreadable }
        if let old = cache[url], old.size == size, old.modified == modified, old.fileNumber == fileNumber {
            return old.reading
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try readHeader(file)
        guard header.isPrimaryDesktop else {
            let result = Reading(header: header, lifecycle: Lifecycle())
            cache[url] = Cached(size: size, modified: modified, fileNumber: fileNumber, reading: result)
            return result
        }
        var window = 32 * 1024
        var state = Lifecycle()
        while true {
            let start = size > UInt64(window) ? size - UInt64(window) : 0
            try file.seek(toOffset: start)
            let data = try file.read(upToCount: min(window, Int(size))) ?? Data()
            var records = data.split(separator: 10, omittingEmptySubsequences: false)
            if start > 0, !records.isEmpty { records.removeFirst() }
            // Ignore a currently-being-written last line until its newline arrives.
            if data.last != 10, !records.isEmpty { records.removeLast() }
            state = Lifecycle()
            for line in records where !line.isEmpty {
                do {
                    let data = Data(line)
                    if try decoder.decode(RecordKind.self, from: data).isTracked {
                        state.apply(try decoder.decode(StatusRecord.self, from: data))
                    }
                } catch {
                    // A damaged status line must not preserve an older successful turn.
                    state.invalidate()
                }
            }
            if state.phase != .unknown || start == 0 || window >= maxBytes { break }
            window = min(window * 2, maxBytes)
        }
        let result = Reading(header: header, lifecycle: state)
        cache[url] = Cached(size: size, modified: modified, fileNumber: fileNumber, reading: result)
        return result
    }

    private func readHeader(_ file: FileHandle) throws -> RolloutHeader {
        var data = Data()
        while data.count < maxBytes {
            let part = try file.read(upToCount: 64 * 1024) ?? Data()
            guard !part.isEmpty else { throw SourceError.malformed }
            if let end = part.firstIndex(of: 10) {
                data.append(part[..<end])
                return try decoder.decode(RolloutHeader.self, from: data)
            }
            data.append(part)
        }
        throw SourceError.oversized
    }
}
