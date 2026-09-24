import Foundation

struct TestEvent {
    let delay: Double
    let bytes: [UInt8]
}
enum TestPattern: String, CaseIterable, Identifiable {
    case single = "Single C4", scale = "C major scale", chord = "C major chord"
    case velocity = "Velocity test", fast = "Fast-note test", program = "Program Change test"
    case bend = "Pitch-bend test", stress = "Stress test"
    var id: String { rawValue }
    func events(channel: UInt8) -> [TestEvent] {
        var events: [TestEvent] = []
        func add(_ time: Double, _ bytes: [UInt8]) { events.append(TestEvent(delay: time, bytes: bytes)) }
        func note(_ note: UInt8, _ time: Double, _ duration: Double, _ velocity: UInt8 = 100) {
            add(time, [0x90 | channel, note, velocity]); add(time + duration, [0x80 | channel, note, 0])
        }
        switch self {
        case .single: note(60, 0, 0.5)
        case .scale:
            for (i, n) in [60, 62, 64, 65, 67, 69, 71, 72].enumerated() { note(UInt8(n), Double(i) * 0.4, 0.3) }
        case .chord: for n: UInt8 in [60, 64, 67] { note(n, 0, 1) }
        case .velocity:
            for (i, v) in [20, 40, 60, 80, 100, 127].enumerated() { note(60, Double(i) * 0.5, 0.35, UInt8(v)) }
        case .fast: for i in 0..<48 { note(UInt8(60 + i % 12), Double(i) * 0.06, 0.04) }
        case .program:
            for i in 0..<4 { add(Double(i), [0xC0 | channel, UInt8(i)]); note(60, Double(i) + 0.1, 0.5) }
        case .bend:
            note(60, 0, 2.1)
            for i in 0...40 {
                let value = Int(8192 + sin(Double(i) / 40 * .pi * 2) * 8191)
                add(Double(i) * 0.05, [0xE0 | channel, UInt8(value & 127), UInt8(value >> 7)])
            }
            add(2.2, [0xE0 | channel, 0, 64])
        case .stress:
            // Include repeated F4 and overlap to reproduce the known pattern-sensitive failure.
            for i in 0..<160 {
                let notes: [UInt8] = [60, 64, 65, 67, 72, 65, 62, 69]
                note(notes[i % notes.count], Double(i) * 0.09, i % 3 == 0 ? 0.14 : 0.055, UInt8(40 + i % 88))
                if i % 8 == 0 { add(Double(i) * 0.09, [0xB0 | channel, 1, UInt8(i % 128)]) }
            }
        }
        return events.enumerated().sorted { a, b in
            a.element.delay == b.element.delay ? a.offset < b.offset : a.element.delay < b.element.delay
        }.map(\.element)
    }
    static func diagnostic(channel: UInt8) -> [TestEvent] {
        [60, 64, 67, 72].enumerated().flatMap { i, n in
            [TestEvent(delay: Double(i) * 0.5, bytes: [0x90 | channel, UInt8(n), 100]),
             TestEvent(delay: Double(i) * 0.5 + 0.35, bytes: [0x80 | channel, UInt8(n), 0])]
        }
    }
}
