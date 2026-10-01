import IOKit.pwr_mgt

/// Holds a "prevent idle sleep" assertion while AI tasks run. The display may still sleep, and closing
/// the lid still sleeps the Mac; macOS does not allow an app to override that.
@MainActor
final class KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func set(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Buddy: keeping the Mac awake while an AI task runs" as CFString, &id)
            guard result == kIOReturnSuccess else { return }
            assertionID = id
            isActive = true
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isActive = false
        }
    }
}
