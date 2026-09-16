import AppKit
import Carbon.HIToolbox

/// Puts text into the app that was frontmost when the user started dictating.
/// Short text is typed as synthetic key events (no clipboard involved, works in terminals).
/// Long text goes through the clipboard + Cmd+V, restoring the old clipboard well after the paste.
final class Paster: @unchecked Sendable {
    private let typeLimit = 1500
    /// Key events are posted here, not on the main thread: we have to sleep a
    /// couple of milliseconds between every single event (see `post`), and
    /// doing that on main freezes the run loop for the whole dictation.
    private let queue = DispatchQueue(label: "ai.learnvector.voicepet.paster")

    /// Types `text` into `target`, reactivating it first if something stole
    /// focus during the transcription gap. Returns true only if the target was
    /// (or became) frontmost AND every character was actually posted -- callers
    /// should treat false as "the text did not reach the user's app."
    func paste(_ text: String, to target: NSRunningApplication?) async -> Bool {
        let focused = await MainActor.run { self.focus(target) }
        if text.count > typeLimit {
            let ok = await MainActor.run { self.pasteViaClipboard(text) }
            return focused && ok
        }
        let posted: Bool = await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.post(text)) }
        }
        return focused && posted
    }

    /// There is a 0.5-2s gap between the user letting go of fn and us having
    /// text to type. Anything can take focus in that window -- the Hub, a
    /// confirm dialog, Spotlight, a notification -- and synthetic key events
    /// go wherever focus actually is, not where the user was looking when they
    /// started talking. So put the original app back in front first.
    /// Returns true if there is nothing to fix or the target is frontmost again.
    @MainActor
    private func focus(_ target: NSRunningApplication?) -> Bool {
        guard let target else { return true }          // nothing was captured; type wherever we are
        guard !target.isTerminated else {
            NSLog("Paster: dictation target has quit, not typing")
            return false
        }
        if target.isActive { return true }
        NSLog("Paster: \(target.localizedName ?? "target") lost focus during transcription, reactivating")
        let ok = target.activate()
        if !ok { NSLog("Paster: could not reactivate \(target.localizedName ?? "target")") }
        // Let the WindowServer actually move key focus before we start posting.
        usleep(120_000)
        return ok
    }

    /// Posts one key event per Character. Returns true if all of them went out.
    private func post(_ text: String) -> Bool {
        NSLog("Paster: post() called, \(text.count) characters / \(text.utf16.count) UTF-16 units")
        // .privateState, NOT .combinedSessionState: a combined-session source
        // inherits whatever modifier keys are PHYSICALLY down at post time
        // (a leftover Cmd, or anything the user happens to be holding), and
        // because we post to the HID tap the flags we clear on the event
        // aren't reliably what the receiver ends up seeing. A private source
        // starts with no modifier state at all, so there is nothing to inherit
        // and `flags = []` below actually means something. Left uncleared, a
        // Chromium-based app (an Electron chat window) sees "Cmd + this
        // character", treats it as a keyboard shortcut instead of text input,
        // and silently swallows the keystroke -- no error, no visible sign,
        // the text just never appears.
        guard let src = CGEventSource(stateID: .privateState) else {
            NSLog("Paster: CGEventSource(.privateState) returned nil, aborting")
            return false
        }
        // Don't let our own posting suppress the user's real keyboard/mouse for
        // the suppression interval after each event. (Spelled out as the union
        // of the three real cases: kCGEventFilterMaskPermitAllEvents is a C
        // macro, so there is no `.permitAllEvents` to import.)
        let permitAll: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        src.setLocalEventsFilterDuringSuppressionState(permitAll, state: .eventSuppressionStateSuppressionInterval)
        src.setLocalEventsFilterDuringSuppressionState(permitAll, state: .eventSuppressionStateRemoteMouseDrag)

        var posted = 0
        // One event per Character, never a batch of UTF-16 units. Batching had
        // two problems: Chromium's key path routinely drops multi-character
        // synthetic payloads (so a log saying "posted 500 chars" could still
        // insert nothing), and a fixed 20-unit chunk boundary could split a
        // surrogate pair down the middle -- leaving each event carrying invalid
        // unpaired UTF-16, which some receivers reject outright. Iterating over
        // Characters keeps every grapheme (emoji, combining accents) intact in
        // a single event by construction.
        for ch in text {
            let units = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
                NSLog("Paster: CGEvent creation failed after \(posted) characters, aborting")
                return false
            }
            down.flags = []
            up.flags = []
            // Only the key-down event carries the character payload. Setting it
            // on key-up too makes some text fields -- web views, Electron apps,
            // chat boxes -- insert the text twice, once per event.
            units.withUnsafeBufferPointer { p in
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: p.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            // A real delay BETWEEN the down and the up, not just between
            // batches. Chromium/Electron move key events across an IPC
            // boundary and can coalesce or drop a down/up pair that arrives
            // with the same timestamp, before the text-insertion path ever
            // runs. Native AppKit fields tolerate it; Electron ones often
            // don't.
            usleep(2000)
            up.post(tap: .cghidEventTap)
            usleep(2000)
            posted += 1
        }
        NSLog("Paster: post() posted \(posted) of \(text.count) characters")
        return posted == text.count
    }

    @MainActor
    private func pasteViaClipboard(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        // Snapshot EVERY representation currently on the pasteboard, not just
        // plain text: clearContents() below destroys an image, a file URL or
        // rich text just as readily, and restoring only .string would silently
        // eat whatever the user actually had copied.
        let saved: [[NSPasteboard.PasteboardType: Data]] = pb.pasteboardItems?.map { item in
            var reps: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { reps[type] = d }
            }
            return reps
        } ?? []
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            NSLog("Paster: could not put text on the pasteboard, aborting")
            return false
        }
        // Give the pasteboard change time to propagate to the target process
        // before Cmd+V asks it to read. Without this the receiver can still be
        // looking at the PREVIOUS contents and paste the wrong thing.
        usleep(50_000)
        sendCmdV()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard pb.string(forType: .string) == text else { return }
            pb.clearContents()
            guard !saved.isEmpty else { return }
            let items: [NSPasteboardItem] = saved.map { reps in
                let item = NSPasteboardItem()
                for (type, data) in reps { item.setData(data, forType: type) }
                return item
            }
            pb.writeObjects(items)
        }
        return true
    }

    private func sendCmdV() {
        guard let src = CGEventSource(stateID: .privateState) else {
            NSLog("Paster: CGEventSource(.privateState) returned nil, cannot send Cmd+V")
            return
        }
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(2000)
        up.post(tap: .cghidEventTap)
    }
}
