import AppKit

/// Hold-to-talk on the Fn (Globe) key. Needs Accessibility trust for the global monitor.
/// macOS must have "Press fn key to: Do Nothing" set, or the Globe key also opens emoji/dictation.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onTalkPress: (() -> Void)?
    var onTalkRelease: (() -> Void)?
    private var monitors: [Any] = []
    private var down = false
    private var talkDown = false
    private let fnKeyCode: UInt16 = 63
    private let rightOptionKeyCode: UInt16 = 61
    /// NX_DEVICERALTKEYMASK from IOKit's IOLLEvent.h -- the bit that says
    /// specifically the RIGHT option key is down, as opposed to NSEvent's
    /// `.option`, which is set by either one. Not exposed to Swift, so it
    /// lives here as the literal it has always been.
    private static let rightOptionMask: UInt = 0x0000_0040

    func start() {
        // `addGlobalMonitorForEvents` for flagsChanged/keyDown/keyUp needs
        // Accessibility trust to actually deliver events -- but it does NOT
        // fail, return nil, or log anything if that trust is missing or
        // stale (e.g. after an ad-hoc rebuild changes the app's signature).
        // It just silently never calls the handler. Log the trust state and
        // whether both tokens registered so a dead monitor is visible in
        // the log instead of indistinguishable from "nothing happened."
        NSLog("HotkeyMonitor: start() called, AXIsProcessTrusted=\(AXIsProcessTrusted())")
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handle(e) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) {
            monitors.append(m)
            NSLog("HotkeyMonitor: global flagsChanged monitor registered")
        } else {
            NSLog("HotkeyMonitor: global flagsChanged monitor FAILED to register")
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in handler(e); return e }) {
            monitors.append(m)
            NSLog("HotkeyMonitor: local flagsChanged monitor registered")
        }
    }

    private func handle(_ e: NSEvent) {
        // Heartbeat: logs EVERY flagsChanged delivery regardless of which key,
        // so a test with Shift/Control/left-Option tells us conclusively
        // whether the monitor is alive at all, independent of whether the fn
        // key specifically is being consumed by something upstream (macOS's
        // own Globe-key handling, or another app's CGEventTap).
        NSLog("HotkeyMonitor: flagsChanged keyCode=\(e.keyCode) flags=\(e.modifierFlags.rawValue)")
        if e.keyCode == fnKeyCode {
            let isDown = e.modifierFlags.contains(.function)
            // Instrumentation for the dictation-doubling bug: log every raw
            // flagsChanged delivery for the fn key so we can see whether the
            // OS/hardware is sending an extra down-up-down-up glitch during
            // what feels like a single continuous hold, vs. the app itself
            // being asked to start/stop twice for one press. Remove once the
            // doubling bug is confirmed fixed.
            NSLog("HotkeyMonitor: fn flagsChanged isDown=\(isDown) currentDown=\(down) ts=\(e.timestamp)")
            if isDown && !down { down = true; onPress?() }
            else if !isDown && down { down = false; onRelease?() }
        } else if e.keyCode == rightOptionKeyCode {
            // `.option` is set by EITHER option key. Using it here meant that
            // if the user happened to be holding LEFT option, releasing RIGHT
            // option still read as "still down": onTalkRelease never fired,
            // the mic kept recording forever, and every subsequent
            // right-option press was swallowed by the !talkDown guard below.
            // The device-specific bit distinguishes the two keys properly.
            let isDown = (e.modifierFlags.rawValue & Self.rightOptionMask) != 0
            if isDown && !talkDown { talkDown = true; onTalkPress?() }
            else if !isDown && talkDown { talkDown = false; onTalkRelease?() }
        }
    }
}

/// Feeds the global cursor position to the pet so its eyes can follow you.
final class CursorTracker {
    static let shared = CursorTracker()
    var onMove: ((Double, Double) -> Void)?
    private var monitor: Any?
    private var last = Date.distantPast

    func start(panel: NSWindow) {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            let now = Date()
            guard now.timeIntervalSince(self.last) > 1.0 / 20.0 else { return }
            self.last = now
            let p = NSEvent.mouseLocation
            let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            // normalised offset from the pet, clamped to [-1, 1]
            let nx = max(-1, min(1, (p.x - c.x) / 400))
            let ny = max(-1, min(1, (p.y - c.y) / 400))
            self.onMove?((nx * 100).rounded() / 100, (ny * 100).rounded() / 100)
        }
    }
}
