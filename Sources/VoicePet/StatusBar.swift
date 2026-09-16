import AppKit

/// The menu bar item next to Wi-Fi and battery: show/hide the pet, open the hub, toggles, quit.
@MainActor
final class StatusBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var app: AppDelegate?
    private let menu = NSMenu()

    init(app: AppDelegate) {
        self.app = app
        super.init()
        item.button?.image = Self.koalaGlyph()
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Koala"
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let app else { return }
        let visible = app.panel.isVisible
        menu.addItem(make(visible ? "Hide the koala" : "Show the koala", #selector(toggleVisible), key: "h"))
        menu.addItem(make("Notes & settings…", #selector(openHub), key: ","))
        menu.addItem(.separator())
        let wander = make("Wanders around", #selector(toggleWander), key: "")
        wander.state = UserDefaults.standard.bool(forKey: "wander") ? .on : .off
        menu.addItem(wander)
        let voice = make("Talks back", #selector(toggleVoice), key: "")
        voice.state = UserDefaults.standard.bool(forKey: "voiceOn") ? .on : .off
        menu.addItem(voice)
        let sounds = make("Sounds", #selector(toggleSounds), key: "")
        sounds.state = UserDefaults.standard.bool(forKey: "sounds") ? .on : .off
        menu.addItem(sounds)
        menu.addItem(.separator())
        menu.addItem(make("Quit Koala", #selector(quit), key: "q"))
    }

    private func make(_ title: String, _ sel: Selector, key: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        m.target = self
        return m
    }

    @objc private func toggleVisible() {
        guard let app else { return }
        if app.panel.isVisible { app.panel.orderOut(nil) } else { app.panel.show() }
    }
    @objc private func openHub() { app?.hub.show() }
    @objc private func toggleWander() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "wander"), forKey: "wander"); app?.applyWanderPref()
    }
    @objc private func toggleVoice() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "voiceOn"), forKey: "voiceOn") }
    @objc private func toggleSounds() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "sounds"), forKey: "sounds"); app?.applySoundsPref()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    /// A tiny koala head: round face with two big round ears, drawn as a template image.
    static func koalaGlyph() -> NSImage {
        let size = NSSize(width: 20, height: 17)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: 6.5, width: 6.5, height: 6.5)).fill()   // left ear
            NSBezierPath(ovalIn: NSRect(x: 13, y: 6.5, width: 6.5, height: 6.5)).fill()    // right ear
            let face = NSBezierPath(ovalIn: NSRect(x: 3, y: 1, width: 14, height: 12))
            face.fill()
            NSColor.clear.setFill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: 2.4, y: 8.4, width: 3, height: 3)).fill()       // left ear inner
            NSBezierPath(ovalIn: NSRect(x: 14.6, y: 8.4, width: 3, height: 3)).fill()      // right ear inner
            NSBezierPath(ovalIn: NSRect(x: 6.6, y: 6.4, width: 1.7, height: 1.7)).fill()   // left eye
            NSBezierPath(ovalIn: NSRect(x: 11.7, y: 6.4, width: 1.7, height: 1.7)).fill()  // right eye
            NSBezierPath(ovalIn: NSRect(x: 7.3, y: 2.6, width: 5.4, height: 3.2)).fill()   // nose
            return true
        }
        img.isTemplate = true
        return img
    }
}
