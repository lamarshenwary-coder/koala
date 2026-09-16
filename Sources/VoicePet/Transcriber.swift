import AVFoundation
import FluidAudio
import Foundation
import Speech

struct TimedWord: Codable { var text: String; var start: Double; var end: Double }

protocol Transcriber: AnyObject {
    var name: String { get }
    var vocabulary: [String] { get set }
    func prepare() async throws
    func transcribe(_ samples16k: [Float]) async throws -> String
    func transcribeTimed(_ samples16k: [Float]) async throws -> [TimedWord]
}

/// Apple's on-device SpeechAnalyzer (macOS 26). No model to ship; the OS downloads the English asset once.
final class AppleTranscriber: Transcriber {
    let name = "Apple on-device"
    var vocabulary: [String] = []
    private var locale = Locale(identifier: "en-US")

    func prepare() async throws {
        try await Self.authorize()
        let supported = await SpeechTranscriber.supportedLocales
        if let l = supported.first(where: { $0.identifier(.bcp47).caseInsensitiveCompare("en-US") == .orderedSame }) { locale = l }
        let t = SpeechTranscriber(locale: locale, preset: .transcription)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await req.downloadAndInstall()
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let words = try await transcribeTimed(samples)
        return Self.join(words)
    }

    func transcribeTimed(_ samples: [Float]) async throws -> [TimedWord] {
        let url = try AudioFileLoader.writeTempCAF(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcribeTimed(fileURL: url)
    }

    func transcribeTimed(fileURL: URL) async throws -> [TimedWord] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: vocabulary]
            try await analyzer.setContext(ctx)
        }
        let file = try AVAudioFile(forReading: fileURL)
        let collector = Task { () throws -> [TimedWord] in
            // SpeechAnalyzer has a known rough edge: for a short utterance, the
            // last final result can be delivered twice -- once as it streams
            // through `transcriber.results` naturally, and again when
            // `finalizeAndFinish(through:)` flushes the tail below. The second
            // pass is a fresh re-decode of the same audio span, so it often
            // comes out with slightly different wording ("koala up" vs
            // "Koala app") and, critically, frequently carries no
            // `audioTimeRange` at all -- so a timestamp-based dedup guard
            // can't catch it. Compare each final result's *words* against the
            // previous one instead: if they're mostly the same set of words,
            // it's a re-emission of the same segment, not new content, so
            // replace the earlier version rather than appending both.
            var segments: [[TimedWord]] = []
            for try await r in transcriber.results where r.isFinal {
                var seg: [TimedWord] = []
                for run in r.text.runs {
                    let text = String(r.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let s = run.audioTimeRange.map { CMTimeGetSeconds($0.start) } ?? (seg.last?.end ?? 0)
                    let d = run.audioTimeRange.map { CMTimeGetSeconds($0.duration) } ?? 0
                    seg.append(TimedWord(text: text, start: s, end: s + d))
                }
                guard !seg.isEmpty else { continue }
                if let last = segments.last, Self.isLikelyReemission(of: last, as: seg) {
                    NSLog("SpeechAnalyzer: treating final as a re-emission, replacing \(last.map(\.text)) with \(seg.map(\.text))")
                    segments[segments.count - 1] = seg
                } else {
                    segments.append(seg)
                }
            }
            let out = segments.flatMap { $0 }
            NSLog("SpeechAnalyzer: collected \(out.count) words: \(out.map(\.text))")
            return out
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await collector.value
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Word-overlap heuristic: are `b`'s words mostly the same set as `a`'s?
    /// Used to catch SpeechAnalyzer re-emitting the same segment on finalize
    /// with slightly different wording, as opposed to a genuinely new,
    /// separate segment of speech (which would share few or no words).
    private static func isLikelyReemission(of a: [TimedWord], as b: [TimedWord]) -> Bool {
        func normalized(_ words: [TimedWord]) -> Set<String> {
            Set(words.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty })
        }
        let wa = normalized(a), wb = normalized(b)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let overlap = wa.intersection(wb).count
        let ratio = Double(overlap) / Double(min(wa.count, wb.count))
        return ratio > 0.5
    }

    static func join(_ words: [TimedWord]) -> String {
        var s = ""
        for w in words {
            if !s.isEmpty, !w.text.hasPrefix(","), !w.text.hasPrefix("."), !w.text.hasPrefix("?"), !w.text.hasPrefix("!") { s += " " }
            s += w.text
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        guard status == .authorized else { throw NSError(domain: "VoicePet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission not granted"]) }
    }
}

/// NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (Core ML, Neural Engine). ~600 MB download on first use.
final class ParakeetTranscriber: Transcriber {
    let name = "Parakeet v3 on-device"
    var vocabulary: [String] = []      // Parakeet has no vocabulary biasing; replacement rules cover it
    private var manager: AsrManager?

    func prepare() async throws {
        if manager != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await result(samples).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribeTimed(_ samples: [Float]) async throws -> [TimedWord] {
        let r = try await result(samples)
        guard let toks = r.tokenTimings, !toks.isEmpty else {
            return [TimedWord(text: r.text, start: 0, end: Double(samples.count) / 16000)]
        }
        var words: [TimedWord] = []
        for t in toks {
            let raw = t.token
            let startsWord = raw.hasPrefix("\u{2581}") || raw.hasPrefix(" ") || words.isEmpty
            let piece = raw.replacingOccurrences(of: "\u{2581}", with: "").trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            if startsWord { words.append(TimedWord(text: piece, start: t.startTime, end: t.endTime)) }
            else { words[words.count - 1].text += piece; words[words.count - 1].end = t.endTime }
        }
        return words
    }

    private func result(_ samples: [Float]) async throws -> ASRResult {
        try await prepare()
        guard let m = manager else { throw NSError(domain: "VoicePet", code: 2, userInfo: [NSLocalizedDescriptionKey: "Parakeet not loaded"]) }
        var state = TdtDecoderState.make(decoderLayers: await m.decoderLayerCount)
        return try await m.transcribe(samples, decoderState: &state)
    }
}
