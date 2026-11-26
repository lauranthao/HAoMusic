// Verbatim from Coda (AGPL-3.0; see CodaPlayerControls.swift header).
// Features/IOSMainWindow.swift — the rotation flag the fluid background
// reads while the window turns. The begin/end wiring (Coda's
// CoverRotationBackdrop) is not copied: without it the flag stays false and
// drawables resize during rotation, which is HAo's existing behaviour.
import Foundation

enum CoverRotation {
    static let didEnd = Notification.Name("CoverRotationDidEnd")
    /// Counted, so a turn that starts before the previous one finishes keeps
    /// the flag set until both have ended.
    private static var active = 0
    static var isActive: Bool { active > 0 }

    static func begin() { active += 1 }

    static func end() {
        guard active > 0 else { return }
        active -= 1
        if active == 0 { NotificationCenter.default.post(name: didEnd, object: nil) }
    }
}
