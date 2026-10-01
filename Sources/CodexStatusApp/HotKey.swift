import Carbon.HIToolbox

/// Global shortcut via Carbon; needs no accessibility or input-monitoring permission.
/// Several instances can coexist: each only reacts to the key it registered.
@MainActor
final class HotKey {
    var onPress: (() -> Void)?
    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(id: UInt32) { self.id = id }

    /// Returns false when the system refuses the combination (for example it is already taken).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            guard read == noErr else { return OSStatus(eventNotHandledErr) }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard pressed.id == hotKey.id else { return false }
                hotKey.onPress?()
                return true
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { return false }
        let hotKeyID = EventHotKeyID(signature: OSType(0x43585354), id: id)  // 'CXST'
        return RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
