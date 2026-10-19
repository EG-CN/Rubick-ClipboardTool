import AppKit
import Testing
@testable import ClipboardTool

@Suite(.serialized)
@MainActor
struct MenuBarPolicyTests {
    @Test func overlappingWindowsNeverPromoteApplicationToRegular() {
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        defer { app.setActivationPolicy(previous) }
        let policy = ActivationPolicyKeeper.shared
        for owner in ["test-settings", "test-panel", "test-inline", "test-overlay"] {
            policy.acquire(owner)
            #expect(app.activationPolicy() == .accessory)
        }
        for owner in ["test-panel", "test-settings", "test-overlay", "test-inline"] {
            policy.release(owner)
            #expect(app.activationPolicy() == .accessory)
        }
    }

    @Test func utilityPanelCanAcceptKeyboardWithoutActivatingApp() {
        _ = NSApplication.shared
        let panel = KeyablePanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120),
                                 styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(panel.canBecomeKey)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }
}
