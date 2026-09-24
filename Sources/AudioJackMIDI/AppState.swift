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
    @Published var devices: [AudioDevice] = []
    @Published var selectedDevice: UInt32 = 0
    @Published var sampleRate = 96000
    @Published var amplitude = 0.90 { didSet { configure() } }
    @Published var reversed = true { didSet { configure() } }
    @Published var velocityZero = false { didSet { configure() } }
    @Published var idleBits = 0 { didSet { configure() } }
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
    func refreshDevices() { devices = AudioOutputEngine.devices() }
    func append(_ message: String) {
        log.append(message)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
    private func configure() {
        let a = Float(amplitude), r = reversed, bits = idleBits, off = velocityZero
        transport.queue.async { [transport] in
            transport.midiParser.velocityZeroNoteOff = off; transport.testParser.velocityZeroNoteOff = off
            if let renderer = transport.engine.renderer { aj_configure(renderer, a, r, UInt32(bits)) }
        }
    }
    func start() {
        guard !busy, !running, portReady else { return }
        busy = true; status = "Starting output…"
        let device = selectedDevice, rate = sampleRate, amp = Float(amplitude), reverse = reversed, bits = idleBits
        transport.queue.async { [weak self, transport] in
            do {
                try transport.engine.start(device: device, rate: rate, amplitude: amp, reversed: reverse, idleBits: bits)
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
            transport.queue.asyncAfter(deadline: .now() + 0.3) { [weak self, transport] in
                transport.engine.stop()
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
                self.activity = self.received != received; self.received = received
                self.sent = sent; self.queued = queued; self.dropped = dropped
                for line in monitor { self.append(line) }
                if let error { self.append(error); self.status = error; self.repeating = false }
                if lost { self.running = false; self.busy = false }
            }
        }
    }
    func shutdown() {
        timer?.invalidate(); port = nil
        transport.queue.sync {
            transport.accepting = false; transport.panic()
            if transport.engine.renderer != nil { Thread.sleep(forTimeInterval: 0.3) }
            transport.engine.stop()
        }
    }
}
