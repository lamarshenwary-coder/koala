import AppKit

/// Floating pill overlay shown while VoicePet is listening/thinking --
/// ported straight from the visual design of Lamar's earlier
/// AI-Dictation-Tool/Handsfree project (src/overlay.py): an audio-reactive
/// bar waveform in a blurred HUD pill, borderless, click-through,
/// always-on-top, centered near the bottom of whichever screen the mouse
/// is currently on. VoicePet's own koala panel stays hidden for now (per
/// "get dictation solid before UI/UX") -- this is a small, separate,
/// purely functional indicator so a hold-to-talk finally has SOME visual
/// feedback, same as Handsfree already gave for free.
final class RecordingOverlay {
    static let shared = RecordingOverlay()

    enum State {
        case recording   // fn dictation, actively capturing
        case command     // right-Option intent, actively capturing
        case transcribing // no live audio left, waiting on the engine/LLM

        var color: NSColor {
            switch self {
            case .recording: return .systemRed
            case .command: return .systemBlue
            case .transcribing: return .systemOrange
            }
        }
    }

    private let pillWidth: CGFloat = 130
    private let pillHeight: CGFloat = 32
    private let barCount = 11
    private let barWidth: CGFloat = 2
    private let barGap: CGFloat = 2
    private let barMinHeight: CGFloat = 3
    private let barMaxHeight: CGFloat = 18
    private let tickInterval: TimeInterval = 1.0 / 24.0

    private var window: NSWindow?
    private var bars: [NSView] = []
    private var timer: Timer?
    private var state: State = .recording
    private var levelHistory: [Float] = []
    private var startTime = Date()
    private var levelProvider: (() -> Float)?

    private init() {}

    // MARK: window / bar construction

    private func ensureWindow() {
        guard window == nil else { return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight))
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = pillHeight / 2
        blur.layer?.masksToBounds = true

        let barsTotalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let barsX = (pillWidth - barsTotalWidth) / 2
        var newBars: [NSView] = []
        for i in 0..<barCount {
            let x = barsX + CGFloat(i) * (barWidth + barGap)
            let bar = NSView(frame: NSRect(x: x, y: (pillHeight - barMinHeight) / 2, width: barWidth, height: barMinHeight))
            bar.wantsLayer = true
            bar.layer?.cornerRadius = barWidth / 2
            bar.layer?.backgroundColor = NSColor.white.cgColor
            blur.addSubview(bar)
            newBars.append(bar)
        }
        win.contentView = blur
        window = win
        bars = newBars
    }

    // MARK: screen placement

    /// Multi-monitor safe: put the pill on whichever screen the user's
    /// mouse (i.e. attention) is currently on, falling back to the main
    /// screen if that ever fails to resolve.
    /// Optional: during a display reconfiguration (or clamshell with no
    /// external display) there may genuinely be no screen, and
    /// `NSScreen.screens.first!` crashed outright. Callers skip the overlay.
    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: animation tick

    /// Glides each bar to its new height instead of snapping (the original
    /// overlay.py just called setFrame_ directly every tick, which reads as
    /// blocky/stepped at 24fps). NSView's `.animator()` proxy routes the
    /// frame change through Core Animation for us, so wrapping the whole
    /// batch in one NSAnimationContext group gives a smooth, springy feel
    /// with a duration slightly longer than the tick interval so consecutive
    /// glides overlap rather than visibly settling between ticks.
    private func setBarHeights(_ heights: [CGFloat]) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = tickInterval * 1.6
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (bar, h) in zip(bars, heights) {
                let hh = max(barMinHeight, min(barMaxHeight, h))
                let f = bar.frame
                bar.animator().frame = NSRect(x: f.origin.x, y: (pillHeight - hh) / 2, width: barWidth, height: hh)
            }
        }
    }

    private func tick() {
        var heights: [CGFloat]
        if state == .transcribing || levelProvider == nil {
            // No live mic level to show while transcribing -- do a gentle
            // idle sweep so the pill still reads as "working".
            let t = Date().timeIntervalSince(startTime)
            heights = (0..<barCount).map { i in
                barMinHeight + (barMaxHeight - barMinHeight) * 0.5 * CGFloat(1 + sin(t * 4 - Double(i) * 0.5))
            }
        } else {
            if let lp = levelProvider {
                levelHistory.append(lp())
                if levelHistory.count > 40 { levelHistory.removeFirst(levelHistory.count - 40) }
            }
            if levelHistory.isEmpty {
                heights = Array(repeating: barMinHeight, count: barCount)
            } else {
                // Downsample the recent level history across the bar count
                // so it reads as a scrolling waveform of actual speech.
                let n = levelHistory.count
                heights = (0..<barCount).map { i -> CGFloat in
                    let idx = min(n - 1, i * n / barCount)
                    let level = levelHistory[idx]
                    // The smoothed level is already 0...1 and fairly
                    // generous (see AudioRecorder), so a straight scale
                    // reads well without the extra boost overlay.py needed
                    // for raw RMS.
                    return barMinHeight + CGFloat(min(1, level)) * (barMaxHeight - barMinHeight)
                }
            }
        }
        let color = state.color.cgColor
        for bar in bars { bar.layer?.backgroundColor = color }
        setBarHeights(heights)
    }

    private func startTimer() {
        stopTimer()
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: public API

    /// levelProvider: pass a closure returning the current smoothed 0...1
    /// mic level (AudioRecorder.level) for .recording/.command. Omit (or
    /// pass nil) for .transcribing, where there's no live audio to show --
    /// the pill falls back to a gentle idle sweep instead.
    func show(_ state: State, levelProvider: (() -> Float)? = nil) {
        ensureWindow()
        guard let window else { return }
        guard let screen = screenUnderMouse()?.frame else { return }
        let x = screen.origin.x + (screen.size.width - pillWidth) / 2
        let y = screen.origin.y + 80   // near the bottom of that screen
        window.setFrameOrigin(NSPoint(x: x, y: y))
        self.state = state
        self.levelProvider = levelProvider
        if levelProvider == nil { levelHistory.removeAll() }
        // Fade in rather than pop, and re-showing while already visible
        // (recording -> transcribing) shouldn't restart the fade from
        // scratch -- only animate up from wherever the alpha currently is.
        let alreadyVisible = window.isVisible && window.alphaValue > 0.01
        if !alreadyVisible { window.alphaValue = 0 }
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = alreadyVisible ? 0 : 0.15
            window.animator().alphaValue = 1
        }
        startTimer()
    }

    func hide() {
        stopTimer()
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 0
        } completionHandler: { [weak window] in
            window?.orderOut(nil)
        }
    }
}
