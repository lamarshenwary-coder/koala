import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let panel = PetPanel()
    let recorder = AudioRecorder()
    let hotkey = HotkeyMonitor()
    let paster = Paster()
    lazy var meeting = MeetingRecorder(mic: recorder)
    /// Touching `hub.isVisible` on the lazy var forces the whole
    /// HubController -- NSHostingView, the full SwiftUI tree, Allowlist.load(),
    /// Keychain.get() -- into existence the first time anything asks, which
    /// (via `wander.isBusy`, 30x/second, and `checkForSleep`, every 10s) meant
    /// building the entire settings UI seconds after launch whether or not the
    /// user ever opened it. `hubIsVisible` answers the question without that.
    private var hubCreated = false
    lazy var hub: HubController = { self.hubCreated = true; return HubController(app: self) }()
    private var hubIsVisible: Bool { hubCreated && hub.isVisible }
    lazy var wander = Wander(panel: panel)
    let voice = PetVoice()
    let brain = Brain()
    lazy var statusBar = StatusBar(app: self)
    private var talking = false
    private(set) var engine: Transcriber = AppleTranscriber()
    private var levelTimer: Timer?
    private var listening = false
    private var engineLoading = false
    private var hasWoken = false
    private var demoTimer: Timer?
    private var lastActivity = Date()
    private var sleepTimer: Timer?
    private var asleep = false
    /// The app that was frontmost when the user started holding fn. There is a
    /// 0.5-2s transcription gap before we have text to type, and anything can
    /// take focus in that window -- synthetic key events go wherever focus
    /// actually is, not where the user was looking when they started talking.
    private var dictationTarget: NSRunningApplication?

    func applicationDidFinishLaunching(_ note: Notification) {
        // FIRST, before anything reads a default. `brain.prepare()` below gates
        // on UserDefaults.bool(forKey: "brainOn"), which returns false for an
        // unregistered key -- so when this call sat further down the method the
        // brain silently never loaded at all on a fresh install.
        UserDefaults.standard.register(defaults: ["sounds": true, "wander": true, "voiceOn": true, "voiceReadBack": false, "voiceName": "Grandpa", "brainOn": true, "chattiness": "some", "brainModel": Brain.defaultTier, "sleepAfterSeconds": 180, "autoDeleteDictations": true])
        // Pet panel hidden while debugging the intent pipeline -- the
        // animated koala + voice were more distracting than useful during
        // this phase. Menu bar icon still works (right-click for Notes/Me),
        // and the hotkeys/dictation/intent code all still run normally --
        // this only hides the visual panel. Call panel.show() again once
        // that's worth turning back on.
        _ = statusBar
        panel.onRightClick = { [weak self] in self?.markActivity(); self?.hub.toggle() }
        panel.onLoaded = { [weak self] in
            self?.panel.js("pet.setState('loading')")
            self?.applySoundsPref()
            self?.panel.webView.evaluateJavaScript("pet.name || 'koala'") { v, _ in if let n = v as? String { self?.brain.petName = n } }
        }
        Task { await brain.prepare() }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForSleep() }
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for var r in Mind.shared.dueNow {
                    r.done = true; Mind.shared.update(r)
                    self.panel.js("pet.setState('done')")
                    self.voice.say("Mm. You asked me to remind you: \(r.text).", force: true)
                }
            }
        }
        Permissions.requestMicrophone()
        Permissions.promptAccessibilityIfNeeded()
        hotkey.onPress = { [weak self] in self?.startListening() }
        hotkey.onRelease = { [weak self] in self?.stopListening() }
        hotkey.onTalkPress = { [weak self] in self?.startTalk() }
        hotkey.onTalkRelease = { [weak self] in self?.stopTalk() }
        hotkey.start()
        CursorTracker.shared.onMove = { [weak self] nx, ny in self?.panel.js("pet.lookAt(\(nx),\(ny))") }
        CursorTracker.shared.start(panel: panel)
        meeting.onStateChange = { [weak self] s in
            self?.markActivity()
            self?.panel.js("pet.setState('\(s)')")
            if s == "noting" { self?.voice.notesStarted() }
            if s == "done", let n = Store.shared.notes.first { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.voice.notesReady(title: n.title) } }
        }
        meeting.engineProvider = { [weak self] in self?.engine ?? AppleTranscriber() }
        meeting.dictationActive = { [weak self] in self?.listening ?? false }
        selectEngine(UserDefaults.standard.string(forKey: "engine") ?? "apple")
        wander.enabled = UserDefaults.standard.bool(forKey: "wander")
        wander.isBusy = { [weak self] in
            guard let self else { return true }
            return self.listening || self.meeting.isRecording || self.meeting.isProcessing || self.hubIsVisible || self.engineLoading
        }
        wander.onVelocity = { [weak self] x, y in self?.panel.js("pet.setVelocity && pet.setVelocity(\(x),\(y))") }
        panel.onGrab = { [weak self] in self?.markActivity(); self?.wander.pause(seconds: 30); self?.voice.grabbed() }
        voice.onTalking = { [weak self] on in self?.panel.js("pet.setTalking && pet.setTalking(\(on))") }
        if CommandLine.arguments.contains("--demo") { runDemo() }
        if CommandLine.arguments.contains("--hub") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.hub.show() } }
    }

    func applyBrainPref() { Task { await brain.prepare() } }

    func applyWanderPref() { wander.enabled = UserDefaults.standard.bool(forKey: "wander") }

    func applySoundsPref() {
        panel.js("pet.setSounds(\(UserDefaults.standard.bool(forKey: "sounds")))")
    }

    // MARK: engine
    func selectEngine(_ id: String) {
        UserDefaults.standard.set(id, forKey: "engine")
        engine = (id == "parakeet") ? ParakeetTranscriber() : AppleTranscriber()
        Task { await warmEngine() }
    }
    @MainActor private func warmEngine() async {
        panel.js("pet.setState('loading')")
        engineLoading = true
        defer { engineLoading = false }
        do {
            try await engine.prepare()
            panel.js("pet.setState('idle')")
            if !hasWoken { hasWoken = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.voice.woke() } }
        } catch {
            NSLog("engine prepare failed: \(error)")
            panel.js("pet.setState('confused')")
        }
    }

    // MARK: push to talk
    func startListening() {
        NSLog("AppDelegate: startListening() called, listening=\(listening) meeting.isRecording=\(meeting.isRecording)")
        guard !listening, !meeting.isRecording else { NSLog("AppDelegate: startListening() ignored (guard failed)"); return }
        markActivity()
        // Snapshot who we are typing into NOW, while the user is still looking
        // at it -- by the time transcription finishes, focus may have moved.
        // Never target ourselves (the pet panel and the Hub are non-activating,
        // so the frontmost app is normally the real one, but be safe).
        let front = NSWorkspace.shared.frontmostApplication
        dictationTarget = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSLog("AppDelegate: dictation target = \(dictationTarget?.localizedName ?? "none")")
        listening = true
        voice.stop()
        do { try recorder.start() } catch {
            NSLog("mic start failed: \(error)")
            listening = false
            panel.js("pet.setState('confused')")
            return
        }
        panel.js("pet.setState('listening')")
        RecordingOverlay.shared.show(.recording, levelProvider: { [weak self] in self?.recorder.level ?? 0 })
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.panel.js("pet.setLevel(\(self.recorder.level))")
        }
    }

    func stopListening() {
        NSLog("AppDelegate: stopListening() called, listening=\(listening)")
        guard listening else { NSLog("AppDelegate: stopListening() ignored (guard failed)"); return }
        listening = false
        levelTimer?.invalidate(); levelTimer = nil
        let samples = recorder.stop()
        NSLog("AppDelegate: stopListening() captured \(samples.count) samples (\(Double(samples.count) / 16000.0)s)")
        guard samples.count > 16000 / 3 else {      // shorter than ~0.3s: treat as an accidental tap
            NSLog("AppDelegate: stopListening() discarding as too short")
            RecordingOverlay.shared.hide()
            panel.js("pet.setState('idle')")
            return
        }
        panel.js("pet.setState('thinking')")
        RecordingOverlay.shared.show(.transcribing)
        let engine = self.engine
        engine.vocabulary = Store.shared.vocabulary.words
        let target = dictationTarget
        // This Task inherits MainActor isolation from the enclosing @MainActor
        // method, so everything below already runs on main -- except the
        // `await paster.paste`, which deliberately suspends so the run loop
        // keeps turning while Paster sleeps between key events.
        // [self] is required: this is an ESCAPING closure, and unlike
        // MainActor.run (which is non-escaping) it does not get implicit self
        // for free. The members below -- panel, voice, paster, brain -- are all
        // instance properties.
        Task { [self] in
            do {
                let raw = try await engine.transcribe(samples)
                RecordingOverlay.shared.hide()
                let text = Store.shared.applyReplacements(raw)
                if text.isEmpty { panel.js("pet.setState('idle')"); voice.heardNothing(); return }
                panel.js("pet.setState('done')")
                let pasted = await paster.paste(text + " ", to: target)
                if !pasted {
                    NSLog("AppDelegate: dictation was NOT delivered to the target app")
                    panel.js("pet.setState('confused')")
                }
                Store.shared.recordDictation(text, pasted: pasted)
                if brain.enabled, brain.isReady, Double.random(in: 0...1) < brain.chattiness {
                    Task { [weak self] in
                        guard let self, let line = await self.brain.react(toDictation: text) else { return }
                        self.voice.say(line)
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.voice.dictated(text) }
                }
            } catch {
                NSLog("transcribe failed: \(error)")
                await MainActor.run { RecordingOverlay.shared.hide(); panel.js("pet.setState('confused')") }
            }
        }
    }

    // MARK: talk to the pet (hold right Option)
    func startTalk() {
        guard !listening, !talking, !meeting.isRecording else { return }
        markActivity()
        talking = true
        voice.stop()
        do { try recorder.start() } catch {
            NSLog("startTalk: mic start failed: \(error)")
            talking = false
            panel.js("pet.setState('confused')")
            return
        }
        panel.js("pet.setState('listening')")
        RecordingOverlay.shared.show(.command, levelProvider: { [weak self] in self?.recorder.level ?? 0 })
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.panel.js("pet.setLevel(\(self.recorder.level))")
        }
    }

    func stopTalk() {
        guard talking else { return }
        talking = false
        levelTimer?.invalidate(); levelTimer = nil
        let samples = recorder.stop()
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let rms = samples.isEmpty ? 0 : (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        NSLog("stopTalk: captured \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / 16000.0))s) peak=\(peak) rms=\(rms)")
        guard samples.count > 16000 / 3 else {
            NSLog("stopTalk: too short, treating as accidental tap")
            RecordingOverlay.shared.hide()
            panel.js("pet.setState('idle')")
            return
        }
        panel.js("pet.setState('thinking')")
        RecordingOverlay.shared.show(.transcribing)
        let engine = self.engine
        Task {
            do {
                let said = try await engine.transcribe(samples)
                NSLog("stopTalk: transcribed = \"\(said)\"")
                if said.isEmpty {
                    await MainActor.run { RecordingOverlay.shared.hide(); panel.js("pet.setState('idle')"); voice.heardNothing() }
                    return
                }

                // Try the command/intent path first. LM Studio must be
                // running with its server on (Settings -> Local Model API)
                // for this to succeed -- if it's not, or the model returns
                // something we can't parse, this falls through to plain
                // chat below rather than leaving the user hanging. The
                // error is logged (not swallowed) so a failure here shows
                // up in Console/Terminal instead of just silently chatting.
                var intent: Intent? = nil
                do {
                    intent = try await IntentGenerator.generate(from: said)
                    NSLog("stopTalk: intent = \(String(describing: intent))")
                } catch {
                    NSLog("IntentGenerator failed: \(error)")
                }

                if let intent, intent.action == "clarify" {
                    await MainActor.run {
                        RecordingOverlay.shared.hide()
                        panel.js("pet.setState('confused')")
                        voice.say(intent.summary, force: true)
                    }
                    return
                }
                if let intent, intent.app != "none" {
                    await MainActor.run { RecordingOverlay.shared.hide() }
                    await handleIntent(intent)
                    return
                }

                await MainActor.run {
                    RecordingOverlay.shared.hide()
                    // brain.status covers off | downloading N% | loading <model> | ready | failed: ….
                    // This used to say "my brain is off" for every one of those except
                    // "downloading", which meant a model that was mid-load, or one whose
                    // download/load genuinely failed, both got reported as "off" -- an
                    // honest failure or a few-second loading gap looked identical to the
                    // toggle actually being unchecked, which sent debugging in the wrong
                    // direction every time.
                    if !brain.enabled {
                        panel.js("pet.setState('done')")
                        voice.say("I heard you, but my brain is off. Turn it on in the Me tab.", force: true)
                    } else if !brain.isReady {
                        panel.js("pet.setState('done')")
                        let status = brain.status
                        let message: String
                        // Trim by the actual prefix word + any separator (space or
                        // colon) rather than a hardcoded character count -- the two
                        // "downloading" status shapes ("downloading 0%" vs
                        // "downloading <model> 42%") have different lengths, and a
                        // fixed dropFirst(N) either mismatched or left a stray leading
                        // space/colon in the spoken message.
                        func afterPrefix(_ prefix: String) -> String {
                            var rest = status.dropFirst(prefix.count)
                            while let first = rest.first, first == " " || first == ":" { rest = rest.dropFirst() }
                            return String(rest)
                        }
                        if status.hasPrefix("downloading") {
                            message = "Mm. My brain is still downloading, \(afterPrefix("downloading"))."
                        } else if status.hasPrefix("loading") {
                            message = "Mm. My brain is still waking up, give it a second."
                        } else if status.hasPrefix("failed") {
                            message = "My brain didn't load right: \(afterPrefix("failed")). Check the Me tab."
                        } else {
                            message = "My brain hasn't started yet. Check the Me tab."
                        }
                        voice.say(message, force: true)
                    }
                }
                guard brain.enabled, brain.isReady else { return }
                let reply = await brain.chat(said)
                await MainActor.run {
                    panel.js("pet.setState('done')")
                    voice.say(reply ?? "Mm.", force: true)
                }
            } catch {
                await MainActor.run { RecordingOverlay.shared.hide(); panel.js("pet.setState('confused')") }
            }
        }
    }

    /// Runs a generated Intent through the allowlist gate, then either
    /// executes it, asks for confirmation, or refuses. Per Lamar's rule:
    /// delete/send/purchase (and anything else in Allowlist.alwaysConfirm)
    /// never run without an explicit yes on the confirm dialog, no matter
    /// what the allowlist otherwise says about that app.
    @MainActor
    private func handleIntent(_ intent: Intent) async {
        func execute() {
            panel.js("pet.setState('done')")
            AppleScriptRunner.run(intent.script) { [weak self] result in
                switch result {
                case .ok:
                    self?.voice.say(intent.summary, force: true)
                case .failed(let msg):
                    NSLog("intent script failed: \(msg)")
                    self?.voice.say("That didn't work: \(msg)", force: true)
                }
            }
        }
        switch ActionGate.evaluate(intent) {
        case .run:
            execute()
        case .confirm(let reason):
            panel.js("pet.setState('confused')")
            let approved = ConfirmDialog.ask(reason)
            ActionGate.log(intent, decision: approved ? "confirmed" : "denied")
            if approved { execute() } else { voice.say("Okay, not doing that.", force: true) }
        case .refuse(let reason):
            panel.js("pet.setState('confused')")
            voice.say(reason, force: true)
        }
    }

    // MARK: sleep when not used
    /// Call whenever the person actually does something with the pet -- dictates,
    /// talks to it, records a meeting, opens the hub, or grabs it. Wakes it
    /// immediately if it was asleep, and resets the countdown either way.
    func markActivity() {
        lastActivity = Date()
        if asleep {
            asleep = false
            panel.js("pet.setState('idle')")
        }
    }

    /// Ticks every 10s; puts the pet to sleep after `sleepAfterSeconds` of nobody
    /// using it. 0 disables. Never fires mid-task or while the hub is open.
    private func checkForSleep() {
        guard !asleep, !listening, !talking, !meeting.isRecording, !meeting.isProcessing, !engineLoading, !hubIsVisible else { return }
        let threshold = TimeInterval(UserDefaults.standard.integer(forKey: "sleepAfterSeconds"))
        guard threshold > 0, Date().timeIntervalSince(lastActivity) >= threshold else { return }
        asleep = true
        panel.js("pet.setState('sleeping')")
    }

    // MARK: demo (cycles states so the pet can be screenshotted)
    private func runDemo() {
        let states = ["idle", "listening", "thinking", "done", "noting", "confused", "sleeping"]
        var i = 0
        var t: Double = 0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            t += 1.0 / 30.0
            if t >= 4 { t = 0; i = (i + 1) % states.count; self.panel.js("pet.setState('\(states[i])')") }
            if states[i] == "listening" { self.panel.js("pet.setLevel(\(abs(sin(t * 6)) * 0.8))") }
        }
    }
}
