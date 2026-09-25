import SwiftUI
import CoreMIDI
import TransportCore

/// All parser, FIFO producer, and audio lifecycle access runs on this serial queue.
final class Transport {
    let queue = DispatchQueue(label: "AudioJack.transport", qos: .userInteractive)
    let engine = AudioOutputEngine()
    let midiParser = MIDISerializer()
    let testParser = MIDISerializer()
    var accepting = false
    let playback = TestPlayback()
    var inputBytes: UInt64 = 0
    var monitor: [String] = []
    var lastError: String?
    @discardableResult
    func receive(_ bytes: [UInt8], time: UInt64, test: Bool = false) -> Bool {
        inputBytes += UInt64(bytes.count)
        if monitor.count < 40 {
            let prefix = test ? "TEST " : "IN   "
            monitor.append(prefix + bytes.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ") + (bytes.count > 48 ? " …" : ""))
        }
        guard accepting, let renderer = engine.renderer else { return false }
        let now = mach_absolute_time()
        // Future timestamps are retained; immediate and late packets use the next audio frame.
        let output = (test ? testParser : midiParser).process(bytes, at: time == 0 ? now : time)
        if !output.isEmpty && !aj_enqueue(renderer, output, UInt32(output.count)) {
            midiParser.reset(); testParser.reset(); playback.discard()
            aj_panic(renderer)
            lastError = "MIDI FIFO overflow: batch dropped; tests cancelled and Panic sent. Reduce the input rate."
            return false
        }
        return true
    }
    func panic() {
        playback.discard(); midiParser.reset(); testParser.reset()
        if let renderer = engine.renderer { aj_panic(renderer) }
    }
    /// Poll asynchronously so large intervals do not block the UI or truncate Panic.
    func finishPanicAndStop(completion: @escaping () -> Void) {
        guard let renderer = engine.renderer else { completion(); return }
        if aj_panic_pending(renderer),
           abs(AudioOutputEngine.nominalRate(engine.device) - Double(engine.sampleRate)) < 1 {
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                finishPanicAndStop(completion: completion)
            }
        } else {
            // Let the final rendered audio reach the device before releasing it.
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                engine.stop()
                completion()
            }
        }
    }
    func restartTest(_ events: [TestEvent], repeatDiagnostic: Bool, channel: UInt8) {
        guard accepting else { return }
        // Do not call aj_panic here: it drops accepted bytes, including Note Offs.
        // Cleanup and the replacement sequence share the same ordered FIFO.
        guard playback.cancel(send: { receive($0, time: 0, test: true) }) else { return }
        schedule(events, token: playback.generation, repeatDiagnostic: repeatDiagnostic, channel: channel)
    }
    func schedule(_ events: [TestEvent], token: Int, repeatDiagnostic: Bool, channel: UInt8) {
        let base = DispatchTime.now() + .milliseconds(5)
        for event in events {
            queue.asyncAfter(deadline: base + event.delay) { [weak self] in
                guard let self, self.accepting, self.playback.generation == token else { return }
                self.playback.deliver(event.bytes, token: token) { self.receive($0, time: 0, test: true) }
            }
        }
        if repeatDiagnostic {
            queue.asyncAfter(deadline: base + 2) { [weak self] in
                guard let self, self.accepting, self.playback.generation == token else { return }
                self.schedule(TestPattern.diagnostic(channel: channel), token: token, repeatDiagnostic: true, channel: channel)
            }
        }
    }
}

final class AppState: ObservableObject {
    static let calibrationAmplitudeLevels = [0.50, 0.60, 0.70, 0.80, 0.85, 0.90, 0.92, 0.94, 0.96, 0.98, 1.00]

    @Published var devices: [AudioDevice] = []
    @Published var selectedDevice: UInt32 = 0 { didSet { refreshOutputVolume() } }
    @Published var sampleRate = 96000
    @Published var amplitude = 0.50 { didSet { configure() } }
    @Published var reversed = true { didSet { configure() } }
    @Published var velocityZero = false { didSet { configure() } }
    @Published var messageIntervalMS = 5.0 { didSet { configure() } }
    @Published var channel = 1
    @Published var running = false
    @Published var busy = false
    @Published var repeating = false
    @Published var portReady = false
    @Published var status = "Output stopped"
    @Published var log: [String] = []
    @Published var received: UInt64 = 0
    @Published var sent: UInt64 = 0
    @Published var queued: UInt32 = 0
    @Published var dropped: UInt64 = 0
    @Published var activity = false
    @Published var outputVolume = OutputVolumeStatus(volume: nil, muted: false)
    @Published var calibrationStep = 1
    @Published var calibrationNote = 60
    @Published var calibrationQuestionVisible = false
    private let transport = Transport()
    private var port: MIDIVirtualPort?
    private var timer: Timer?
    private var polls = 0

    init() {
        refreshDevices()
        selectedDevice = devices.first(where: { $0.id == AudioOutputEngine.defaultDevice() })?.id ?? devices.first?.id ?? 0
        do {
            let transport = self.transport
            port = try MIDIVirtualPort { [weak transport] bytes, time in
                transport?.queue.async { [weak transport] in transport?.receive(bytes, time: time) }
            }
            portReady = true; append("Virtual destination ready: AudioJack MIDI Out")
        } catch { status = error.localizedDescription; append(status) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
    }
    var supportedRates: [Int] { devices.first(where: { $0.id == selectedDevice })?.rates ?? [] }
    var calibrationAvailable: Bool { !outputVolume.needsAttention }
    var outputVolumePercent: Int? { outputVolume.volume.map { Int(($0 * 100).rounded()) } }
    func refreshDevices() {
        guard !running, !busy else { return }
        let previousDevices = devices
        let selectedName = previousDevices.first(where: { $0.id == selectedDevice })?.name.lowercased() ?? ""
        let laptopSpeakersSelected = selectedName.contains("speakers") &&
            (selectedName.contains("macbook") || selectedName.contains("built-in") || selectedName.contains("internal"))
        let nextDevices = AudioOutputEngine.devices()
        if devices != nextDevices { devices = nextDevices }
        if laptopSpeakersSelected,
           let headphones = nextDevices.first(where: { $0.name.caseInsensitiveCompare("External Headphones") == .orderedSame }),
           !previousDevices.contains(where: { $0.id == headphones.id && $0.name == headphones.name }) {
            selectedDevice = headphones.id
        } else if !nextDevices.contains(where: { $0.id == selectedDevice }) {
            selectedDevice = nextDevices.first(where: { $0.id == AudioOutputEngine.defaultDevice() })?.id ?? nextDevices.first?.id ?? 0
        }
        refreshOutputVolume()
    }
    func refreshOutputVolume() {
        let next = selectedDevice == 0 ? OutputVolumeStatus(volume: nil, muted: false)
            : AudioOutputEngine.outputVolumeStatus(selectedDevice)
        if outputVolume != next { outputVolume = next }
    }
    func append(_ message: String) {
        log.append(message)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
    private func configure() {
        let a = Float(amplitude), r = reversed, off = velocityZero, interval = messageIntervalMS
        transport.queue.async { [transport] in
            transport.midiParser.velocityZeroNoteOff = off; transport.testParser.velocityZeroNoteOff = off
            if let renderer = transport.engine.renderer {
                aj_configure(renderer, a, r, 0)
                aj_set_message_interval(renderer, interval)
            }
        }
    }
    func start() {
        guard !busy, !running, portReady else { return }
        busy = true; status = "Starting output…"
        let device = selectedDevice, rate = sampleRate, amp = Float(amplitude), reverse = reversed, interval = messageIntervalMS
        transport.queue.async { [weak self, transport] in
            do {
                try transport.engine.start(device: device, rate: rate, amplitude: amp, reversed: reverse, idleBits: 0, messageIntervalMS: interval)
                transport.midiParser.reset(); transport.testParser.reset(); transport.playback.discard(); transport.accepting = true
                DispatchQueue.main.async { [weak self] in
                    self?.running = true; self?.busy = false
                    self?.status = "Running · \(rate / 1000) kHz stereo"
                    self?.append("Output started at \(rate) Hz; device \(device).")
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.busy = false; self?.status = message; self?.append(message) }
            }
        }
    }
    func stop() {
        guard !busy, running else { return }
        busy = true; repeating = false; status = "Sending Panic, then stopping…"
        transport.queue.async { [weak self, transport] in
            transport.accepting = false; transport.panic()
            transport.finishPanicAndStop { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.running = false; self?.busy = false; self?.status = "Output stopped"
                    self?.append("Panic sent; output stopped.")
                }
            }
        }
    }
    func panic() {
        repeating = false
        transport.queue.async { [transport] in transport.panic() }
        append(running ? "PANIC · CC123, CC120, pitch center on all 16 channels; queued MIDI cleared." : "Output is stopped. Start output to transmit Panic.")
    }
    func run(_ pattern: TestPattern) {
        guard running, !busy else { return }
        repeating = false
        let ch = UInt8(channel - 1)
        transport.queue.async { [transport] in
            transport.restartTest(pattern.events(channel: ch), repeatDiagnostic: false, channel: ch)
        }
        append("Test: \(pattern.rawValue), MIDI channel \(channel)")
    }
    func playCalibrationTest() {
        guard calibrationAvailable, running, !busy else { return }
        let ch = UInt8(channel - 1)
        let note = UInt8(min(127, max(0, calibrationNote)))
        let events: [TestEvent]
        if calibrationStep == 1 {
            events = [
                TestEvent(delay: 0, bytes: [0x90 | ch, note, 100]),
                TestEvent(delay: 0.5, bytes: [0x80 | ch, note, 0])
            ]
        } else {
            events = TestPattern.calibrationBurst(channel: ch, note: note)
        }
        transport.queue.async { [transport] in
            transport.restartTest(events, repeatDiagnostic: false, channel: ch)
        }
        calibrationQuestionVisible = true
        append(calibrationStep == 1 ? "Calibration test note at \(Int(amplitude * 100))%." : "Calibration burst at \(messageIntervalMS) ms spacing.")
    }
    func calibrationWorked() {
        guard calibrationQuestionVisible else { return }
        calibrationQuestionVisible = false
        if calibrationStep == 1 { calibrationStep = 2 }
    }
    func calibrationFailed() {
        guard calibrationQuestionVisible else { return }
        if calibrationStep == 1 {
            amplitude = Self.calibrationAmplitudeLevels.first(where: { $0 > amplitude + 0.001 }) ?? 1.0
        } else {
            let gaps = [0.0, 0.5, 1.0, 2.0, 3.0, 5.0, 7.5, 10.0, 15.0, 20.0]
            messageIntervalMS = gaps.first(where: { $0 > messageIntervalMS + 0.001 }) ?? 20.0
        }
        calibrationQuestionVisible = false
    }
    func toggleDiagnostic() {
        guard running, !busy else { return }
        if repeating { panic(); return }
        repeating = true
        let ch = UInt8(channel - 1)
        transport.queue.async { [transport] in
            transport.restartTest(TestPattern.diagnostic(channel: ch), repeatDiagnostic: true, channel: ch)
        }
        append("Repeating C4 → E4 → G4 → C5 on channel \(channel).")
    }
    private func poll() {
        polls += 1
        let checkDevice = polls % 20 == 0
        if checkDevice {
            if !running && !busy { refreshDevices() }
            else { refreshOutputVolume() }
        }
        transport.queue.async { [weak self, transport] in
            let received = transport.inputBytes, monitor = transport.monitor
            transport.monitor.removeAll(keepingCapacity: true)
            let renderer = transport.engine.renderer
            let sent = renderer.map { aj_transmitted($0) } ?? 0
            let queued = renderer.map { aj_pending($0) } ?? 0
            let dropped = renderer.map { aj_dropped($0) } ?? 0
            var error = transport.lastError; transport.lastError = nil
            var lost = false
            if checkDevice && transport.accepting && abs(AudioOutputEngine.nominalRate(transport.engine.device) - Double(transport.engine.sampleRate)) > 1 {
                transport.accepting = false; transport.playback.discard(); transport.engine.stop(); lost = true
                error = "Output device disconnected or sample rate changed. Output stopped; reconnect and restart."
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let activity = self.received != received
                if self.activity != activity { self.activity = activity }
                if self.received != received { self.received = received }
                if self.sent != sent { self.sent = sent }
                if self.queued != queued { self.queued = queued }
                if self.dropped != dropped { self.dropped = dropped }
                if !monitor.isEmpty { self.log = Array((self.log + monitor).suffix(200)) }
                if let error { self.append(error); self.status = error; self.repeating = false }
                if lost { self.running = false; self.busy = false }
            }
        }
    }
    func shutdown(completion: @escaping () -> Void) {
        timer?.invalidate(); port = nil
        busy = true; status = "Sending Panic before quitting…"
        transport.queue.async { [transport] in
            transport.accepting = false; transport.panic()
            transport.finishPanicAndStop {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }
}
