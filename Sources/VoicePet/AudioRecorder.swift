import AVFoundation
import CoreAudio

/// Captures the default mic and accumulates 16 kHz mono Float32 samples. `level` is a smoothed 0...1 loudness.
final class AudioRecorder {
    // AVAudioEngine.inputNode binds to whichever device was the system
    // default the FIRST time it was touched, and reusing one engine
    // instance across stop()/start() cycles never rebinds it -- even after
    // the user picks a different input device in System Settings. That
    // produces exactly-zero samples at the right duration/count if the
    // default input was ever something silent (a disconnected device, a
    // virtual loopback device like BlackHole) at any point since launch.
    //
    // The fix isn't "recreate the engine on every start()", though -- that
    // was tried and caused a *worse* regression: tearing down and building
    // a brand new AVAudioEngine on every single hold-to-talk press churns
    // through Core Audio hardware taps constantly, and a rapid stop() then
    // start() can race with Core Audio actually releasing the previous
    // engine's grip on the input device. The new engine reports a
    // perfectly valid sampleRate and engine.start() doesn't throw, but no
    // buffers ever arrive on the tap -- which shows up as exactly
    // "captured 0 samples" even for a confirmed multi-second hold. That's
    // the bug this version fixes: only tear down and rebuild the engine
    // when the default input device has *actually changed* since the last
    // start(), otherwise reuse the same engine instance (which is fine
    // across stop()/start() as long as the device hasn't moved).
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var buffer: [Float] = []
    private let lock = NSLock()
    private(set) var level: Float = 0
    /// When set, samples stream here instead of accumulating in memory (meeting mode).
    /// Read on the CoreAudio render thread, written from the main actor by
    /// MeetingRecorder -- so it goes through the same NSLock as `buffer` and
    /// `level`. It used to be a plain var read outside the lock at the call
    /// site, an unsynchronised race on a closure reference that can over-release
    /// and crash rather than merely misbehave.
    var onSamples: (([Float]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onSamples }
        set { lock.lock(); _onSamples = newValue; lock.unlock() }
    }
    private var _onSamples: (([Float]) -> Void)?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var lastDefaultInputDeviceID: AudioDeviceID?
    private var loggedFirstBufferThisRun = false

    enum RecorderError: Error { case noInput }

    /// Reads the current system default input device id via CoreAudio, so
    /// start() can tell "device changed, need a fresh engine" apart from
    /// "same device, reuse the engine".
    private static func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    func start() throws {
        lock.lock(); buffer.removeAll(keepingCapacity: true); level = 0; lock.unlock()
        loggedFirstBufferThisRun = false

        let currentDevice = Self.currentDefaultInputDeviceID()
        if engine == nil || currentDevice != lastDefaultInputDeviceID {
            if let old = engine {
                old.inputNode.removeTap(onBus: 0)
                old.stop()
            }
            NSLog("AudioRecorder: building fresh AVAudioEngine (device changed \(String(describing: lastDefaultInputDeviceID)) -> \(String(describing: currentDevice)))")
            engine = AVAudioEngine()
            lastDefaultInputDeviceID = currentDevice
        }
        guard let engine else { throw RecorderError.noInput }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw RecorderError.noInput }
        converter = AVAudioConverter(from: fmt, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in self?.handle(buf) }
        engine.prepare()
        try engine.start()
        NSLog("AudioRecorder: start() ok, device=\(String(describing: currentDevice)) sampleRate=\(fmt.sampleRate) channels=\(fmt.channelCount) engineRunning=\(engine.isRunning)")
    }

    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        lock.lock(); defer { lock.unlock() }
        if buffer.isEmpty {
            NSLog("AudioRecorder: stop() returning EMPTY buffer -- tap never delivered a single frame this run")
        }
        return buffer
    }

    private func handle(_ buf: AVAudioPCMBuffer) {
        if !loggedFirstBufferThisRun {
            loggedFirstBufferThisRun = true
            NSLog("AudioRecorder: first tap buffer arrived, frameLength=\(buf.frameLength) format=\(buf.format)")
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.floatChannelData else { return }
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        let samples = UnsafeBufferPointer(start: ch[0], count: n)
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        lock.lock()
        let sink = _onSamples
        if sink == nil { buffer.append(contentsOf: samples) }
        level = level * 0.6 + min(1, rms * 10) * 0.4
        lock.unlock()
        sink?(Array(samples))
    }
}

enum AudioFileLoader {
    /// Reads any audio file and returns 16 kHz mono Float32 samples.
    static func load16kMono(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: inBuf)
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16000 / file.processingFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return [] }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        if let err { throw err }
        guard let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// Writes 16 kHz mono samples to a temporary CAF file (for engines that want a file).
    static func writeTempCAF(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voicepet-\(UUID().uuidString).caf")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return url }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
        try file.write(from: buf)
        return url
    }
}
