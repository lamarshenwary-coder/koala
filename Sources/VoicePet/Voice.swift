import AVFoundation
import Foundation

/// The pet talks back with one of macOS's built-in novelty voices.
@MainActor
final class PetVoice: NSObject, AVSpeechSynthesizerDelegate {
    /// The full "novelty"/character voice catalog Apple has shipped across
    /// macOS releases -- not all of these exist on every machine or OS
    /// version (some need a separate download in System Settings ->
    /// Accessibility -> Spoken Content -> System Voice, and Apple has
    /// added/renamed a few over the years). `voices` below filters this
    /// down to whichever are actually installed and speakable on THIS Mac,
    /// so the picker never shows a button that silently does nothing.
    private static let noveltyCandidates = [
        "Grandpa", "Grandma", "Bad News", "Good News", "Jester", "Boing", "Bubbles",
        "Zarvox", "Trinoids", "Cellos", "Bells", "Bahh", "Albert", "Whisper",
        "Wobble", "Hysterical", "Deranged", "Pipe Organ", "Organ", "Kathy",
        "Fred", "Junior", "Ralph", "Rocko", "Superstar", "Eddy", "Flo", "Reed", "Sandy", "Shelley"
    ]

    /// Only the candidates above that are actually installed on this Mac, in
    /// the curated order (so the silly ones show first, matching the pet's
    /// character), followed by any OTHER installed English voice that isn't
    /// in that list -- e.g. a Siri/Enhanced voice someone downloaded -- so
    /// nothing already on the machine goes missing just because it wasn't
    /// hardcoded here.
    static var voices: [String] {
        let installed = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.map { $0.name }
        let installedSet = Set(installed)
        let novelty = noveltyCandidates.filter { installedSet.contains($0) }
        let rest = Set(installed).subtracting(novelty).sorted()
        return novelty + rest
    }
    private let synth = AVSpeechSynthesizer()
    private var lastQuip = Date.distantPast
    var onTalking: ((Bool) -> Void)?

    var enabled: Bool { UserDefaults.standard.bool(forKey: "voiceOn") }
    var readBack: Bool { UserDefaults.standard.bool(forKey: "voiceReadBack") }
    var voiceName: String { UserDefaults.standard.string(forKey: "voiceName") ?? "Grandpa" }

    override init() {
        super.init()
        synth.delegate = self
    }

    static func voice(named name: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().first { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.language.hasPrefix("en") }
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Hard mute switch for while we're debugging the intent pipeline --
    /// the pet's chatter was getting in the way. Flip back to false once
    /// the koala/voice UX is worth turning on again.
    static let debugSilenced = true

    func say(_ text: String, force: Bool = false) {
        // `force` means "this is not ambient chatter, it is something the user
        // needs to hear" -- an intent clarification, a failed script, "my brain
        // is off". debugSilenced used to short-circuit BEFORE this check, so it
        // muted those too and every failure produced literally no feedback at
        // all. debugSilenced now only suppresses the optional chatter.
        guard force || !Self.debugSilenced, enabled || force, !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice(named: voiceName)
        u.rate = 0.48
        u.pitchMultiplier = 1.15
        u.volume = 0.9
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// A short remark, not every time, never twice in a row too quickly.
    func quip(_ options: [String], chance: Double = 1.0) {
        guard enabled, Date().timeIntervalSince(lastQuip) > 4, Double.random(in: 0...1) < chance else { return }
        lastQuip = Date()
        say(options.randomElement()!)
    }

    // events
    func woke() { quip(["Mm. I'm awake.", "Hello there.", "Koala online.", "Ready when you are."]) }
    func dictated(_ text: String) {
        if readBack { say(text); return }
        quip(["Mm. Typed.", "Got it.", "Words delivered.", "Done and done.", "Sent to the keyboard.", "Nice one.", "There you go."], chance: 0.5)
    }
    func heardNothing() { quip(["Hmm? I didn't catch that.", "Say again?", "Nothing came through, sorry."]) }
    func notesStarted() { say("Taking notes. Carry on.") }
    func notesReady(title: String) { say("Notes are ready. \(title).") }
    func grabbed() { quip(["Hey!", "Careful, I was napping.", "Put me down.", "Whee."], chance: 0.8) }
    func test() { say("Mm. This is my voice. I type what you say.", force: true) }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { Task { @MainActor in self.onTalking?(true) } }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Task { @MainActor in self.onTalking?(false) } }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { Task { @MainActor in self.onTalking?(false) } }
}
