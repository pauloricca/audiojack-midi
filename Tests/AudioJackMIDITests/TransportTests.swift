import XCTest
import TransportCore
@testable import AudioJackMIDI

final class TransportTests: XCTestCase {
    func render(_ renderer: OpaquePointer, frames: Int, host: UInt64 = 0) -> ([Float], [Float]) {
        var left = [Float](repeating: 7, count: frames), right = left
        aj_render(renderer, &left, &right, UInt32(frames), host)
        return (left, right)
    }
    func enqueue(_ renderer: OpaquePointer, _ bytes: [UInt8], end: Bool = false, time: UInt64 = 0) {
        let entries = bytes.map { AJByte(byte: $0, messageEnd: end ? 1 : 0, hostTime: time) }
        XCTAssertTrue(aj_enqueue(renderer, entries, UInt32(entries.count)))
    }
    func test192kHzRetainsAbsoluteRoundedBitBoundaries() {
        for rate: UInt32 in [192000] {
            let r = aj_create(rate, Double(rate))!; defer { aj_destroy(r) }
            let bytes: [UInt8] = (0..<3125).map { UInt8(truncatingIfNeeded: $0 * 73 + 65) }
            enqueue(r, bytes)
            let frames = Int(rate) + 1
            let (left, right) = render(r, frames: frames)
            // Independent oracle: absolute bit times rounded to the nearest sample.
            for bit in 0..<(bytes.count * 10) {
                let start = Int((Double(bit) * Double(rate) / 31250).rounded())
                let end = Int((Double(bit + 1) * Double(rate) / 31250).rounded())
                let part = bit % 10
                let zero = part == 0 || (part < 9 && bytes[bit / 10] & (1 << (part - 1)) == 0)
                for sample in start..<end {
                    if left[sample] != (zero ? -0.9 : 0) || right[sample] != -left[sample] {
                        XCTFail("Mismatch at rate \(rate), bit \(bit), sample \(sample)"); return
                    }
                }
            }
            XCTAssertEqual(left[Int(rate)], 0)
            XCTAssertEqual(aj_transmitted(r), UInt64(bytes.count))
        }
    }
    /// Independent oracle: rounded BYTE boundaries, fixed three-sample active bits.
    private func assert96kHzWaveform(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        let r = aj_create(96000, 96000)!; defer { aj_destroy(r) }
        aj_set_pulse_strategy(r, 1)
        enqueue(r, bytes)
        let duration = Int((Double(bytes.count) * 30.72).rounded())
        let (left, right) = render(r, frames: duration + 1)
        for (index, byte) in bytes.enumerated() {
            let start = Int((Double(index) * 30.72).rounded())
            let end = Int((Double(index + 1) * 30.72).rounded())
            XCTAssertTrue([3, 4].contains(end - start - 27), file: file, line: line)
            for offset in 0..<(end - start) {
                let bit = offset / 3
                let zero = bit == 0 || (bit < 9 && byte & (1 << (bit - 1)) == 0)
                let expected: Float = zero ? -0.9 : 0
                if left[start + offset] != expected || right[start + offset] != -expected {
                    XCTFail("Byte \(index), value \(byte), sample offset \(offset): START/data must be exactly 3 samples", file: file, line: line)
                    return
                }
            }
        }
        XCTAssertEqual(left[duration], 0, file: file, line: line)
        XCTAssertEqual(aj_transmitted(r), UInt64(bytes.count), file: file, line: line)
    }

    func test96kHzEveryByteValueAtEveryStopAccumulatorPhase() {
        // 256 byte values × all 25 phases of the .72-sample remainder.
        let bytes = (0..<6400).map { UInt8(truncatingIfNeeded: $0 * 73 + 65) }
        assert96kHzWaveform(bytes)
    }

    func test96kHzTailStretchIsDefaultAndExtendsOnlyFirstSampleAfterIsolatedZero() {
        // 0x2A = D0..D7 0,1,0,1,0,1,0,0. D2 and D4 are isolated zeroes.
        let r = aj_create(96000, 96000)!; defer { aj_destroy(r) }
        enqueue(r, [0x2A])
        let left = render(r, frames: 40).0

        XCTAssertEqual(left[11], -0.9) // final D2 sample
        XCTAssertEqual(left[12], -0.9) // one-sample tail into D3
        XCTAssertEqual(left[13], 0)
        XCTAssertEqual(left[17], -0.9) // final D4 sample
        XCTAssertEqual(left[18], -0.9) // one-sample tail into D5
        XCTAssertEqual(left[19], 0)
    }

    func test96kHzLegacyStrategyLeavesFollowingOneUntouched() {
        let r = aj_create(96000, 96000)!; defer { aj_destroy(r) }
        aj_set_pulse_strategy(r, 1)
        enqueue(r, [0x2A])
        let left = render(r, frames: 40).0
        XCTAssertEqual(left[11], -0.9)
        XCTAssertEqual(left[12], 0)
        XCTAssertEqual(left[17], -0.9)
        XCTAssertEqual(left[18], 0)
    }

    func test96kHzStopReservoirHasCorrectAverageByteDuration() {
        let r = aj_create(96000, 96000)!; defer { aj_destroy(r) }
        enqueue(r, [UInt8](repeating: 0, count: 25))
        let wave = render(r, frames: 769).0
        let starts = (0..<768).filter { wave[$0] < 0 && ($0 == 0 || wave[$0 - 1] == 0) }
        XCTAssertEqual(starts.count, 25)
        let widths = zip(starts, Array(starts.dropFirst()) + [768]).map { $1 - $0 - 27 }
        XCTAssertEqual(widths.filter { $0 == 4 }.count, 18)
        XCTAssertEqual(widths.filter { $0 == 3 }.count, 7)
        XCTAssertEqual(aj_transmitted(r), 25)
    }

    func test96kHzStressBytesIncludingF4NoteOffUseFixedActiveBits() {
        // Keep the existing generator unchanged; exercise its byte patterns back-to-back.
        let bytes = TestPattern.stress.events(channel: 0).flatMap(\.bytes)
        XCTAssertTrue(TestPattern.stress.events(channel: 0).contains { $0.bytes == [0x80, 65, 0] })
        assert96kHzWaveform(bytes)
    }

    func testBufferBoundariesDoNotChangeWaveform() {
        let a = aj_create(96000, 96000)!, b = aj_create(96000, 96000)!
        defer { aj_destroy(a); aj_destroy(b) }
        let bytes: [UInt8] = [0x90, 60, 100, 0xF8, 0x80, 60, 0]
        enqueue(a, bytes); enqueue(b, bytes)
        let whole = render(a, frames: 400).0
        var fragmented: [Float] = []
        for chunk in [1, 2, 7, 13, 64, 3, 127, 183] {
            fragmented += render(b, frames: chunk, host: UInt64(fragmented.count)).0
        }
        XCTAssertEqual(whole, fragmented)
    }
    func testIdleAndTimestamp() {
        let r = aj_create(96000, 96000)!; defer { aj_destroy(r) }
        enqueue(r, [0], time: 50)
        let (left, right) = render(r, frames: 100)
        XCTAssertTrue(left.prefix(50).allSatisfy { $0 == 0 })
        XCTAssertEqual(left[50], -0.9)
        XCTAssertTrue(left.suffix(20).allSatisfy { $0 == 0 })
        XCTAssertEqual(right[50], 0.9)
    }
    func testPolarityAmplitudeAndMessageGap() {
        let r = aj_create(96000, 96000)!; defer { aj_destroy(r) }
        aj_configure(r, 0.75, false, 4)
        enqueue(r, [0, 0], end: true)
        let (left, right) = render(r, frames: 90)
        XCTAssertEqual(left[0], 0.75); XCTAssertEqual(right[0], -0.75)
        // Second start is round((10 UART + 4 idle) * 3.072) = 43.
        XCTAssertTrue(left[28..<43].allSatisfy { $0 == 0 })
        XCTAssertEqual(left[43], 0.75)
    }
    func testOverflowIsAtomic() {
        let r = aj_create(96000, 96000)!; defer { aj_destroy(r) }
        enqueue(r, [UInt8](repeating: 0, count: 65535))
        let extra = [AJByte(byte: 1, messageEnd: 0, hostTime: 0), AJByte(byte: 2, messageEnd: 0, hostTime: 0)]
        XCTAssertFalse(aj_enqueue(r, extra, 2))
        XCTAssertEqual(aj_pending(r), 65535); XCTAssertEqual(aj_dropped(r), 2)
    }
    func testPanicBypassesFutureBacklogAndSendsAllChannels() {
        let r = aj_create(96000, 96000)!; defer { aj_destroy(r) }
        enqueue(r, [0x90, 65, 127], time: 99999999)
        aj_panic(r)
        let wave = render(r, frames: 5000).0
        var decoded: [UInt8] = []
        for index in 0..<144 {
            var byte: UInt8 = 0
            for bit in 0..<8 {
                let sample = Int((Double(index) * 30.72).rounded()) + (bit + 1) * 3 + 1
                if wave[sample] == 0 { byte |= 1 << bit }
            }
            decoded.append(byte)
        }
        let expected: [UInt8] = (0..<16).flatMap { (channel: Int) -> [UInt8] in
            [UInt8(0xB0 + channel), 123, 0, UInt8(0xB0 + channel), 120, 0, UInt8(0xE0 + channel), 0, 64]
        }
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(aj_pending(r), 0); XCTAssertEqual(aj_transmitted(r), 144)
    }
    func testPanicFinishesCurrentByte() {
        let r = aj_create(96000, 96000)!; defer { aj_destroy(r) }
        enqueue(r, [0x90, 60, 127])
        let first = render(r, frames: 5).0
        aj_panic(r)
        let wave = first + render(r, frames: 5000, host: 5).0
        for bit in 0..<8 {
            let sample = (bit + 1) * 3 + 1
            XCTAssertEqual(wave[sample] == 0, 0x90 & (1 << bit) != 0)
        }
        XCTAssertEqual(aj_transmitted(r), 145)
    }
    func testRunningStatusAndRealTimeInterleaving() {
        let parser = MIDISerializer()
        let output = parser.process([0x90, 60, 0xF8, 100, 64, 110, 0xFA, 0xFC], at: 42)
        XCTAssertEqual(output.map(\.byte), [0x90, 60, 0xF8, 100, 0x90, 64, 110, 0xFA, 0xFC])
        XCTAssertEqual(output.map(\.messageEnd), [0, 0, 0, 1, 0, 0, 1, 1, 1])
        XCTAssertTrue(output.allSatisfy { $0.hostTime == 42 })
    }
    func testFragmentedNoteOffConversion() {
        let parser = MIDISerializer(); parser.velocityZeroNoteOff = true
        XCTAssertEqual(parser.process([0x82, 65], at: 0).map(\.byte), [0x92, 65])
        XCTAssertEqual(parser.process([0xF8, 99, 66, 80], at: 1).map(\.byte), [0xF8, 0, 0x92, 66, 0])
    }
    func testAllChannelAndSystemMessageLengths() {
        let parser = MIDISerializer()
        let input: [UInt8] = [0xA2, 65, 70, 0xB2, 1, 127, 0xC2, 4, 5, 0xD2, 80, 90, 0xE2, 0, 64,
                              0xF1, 10, 0xF2, 1, 2, 0xF3, 3, 0xF6, 0xFB, 0xFE, 0xFF]
        XCTAssertEqual(parser.process(input, at: 0).map(\.byte),
                       [0xA2, 65, 70, 0xB2, 1, 127, 0xC2, 4, 0xC2, 5, 0xD2, 80, 0xD2, 90, 0xE2, 0, 64,
                        0xF1, 10, 0xF2, 1, 2, 0xF3, 3, 0xF6, 0xFB, 0xFE, 0xFF])
    }
    func testSysExAndCommonCancelRunningStatus() {
        let parser = MIDISerializer()
        let input: [UInt8] = [0x90, 60, 100, 0xF0, 0x7D, 0xF8, 1, 0xF7, 61, 100, 0xF2, 0, 0, 62, 100]
        XCTAssertEqual(parser.process(input, at: 0).map(\.byte), [0x90, 60, 100, 0xF0, 0x7D, 0xF8, 1, 0xF7, 0xF2, 0, 0])
    }
    func testGeneratorBalancesNotesAndIncludesF4() {
        for pattern in TestPattern.allCases {
            var held: [UInt8: Int] = [:]
            let events = pattern.events(channel: 1)
            XCTAssertEqual(events.map(\.delay), events.map(\.delay).sorted())
            for event in events {
                XCTAssertEqual(event.bytes[0] & 15, 1)
                if event.bytes[0] & 0xF0 == 0x90 { held[event.bytes[1], default: 0] += 1 }
                if event.bytes[0] & 0xF0 == 0x80 { held[event.bytes[1], default: 0] -= 1 }
            }
            XCTAssertTrue(held.values.allSatisfy { $0 == 0 }, pattern.rawValue)
        }
        XCTAssertTrue(TestPattern.stress.events(channel: 0).contains { $0.bytes == [0x80, 65, 0] })
    }

    func testCalibrationBurstBalancesNotesAndIncludesControllerTraffic() {
        let events = TestPattern.calibrationBurst(channel: 5, note: 60)
        var held: [UInt8: Int] = [:]
        XCTAssertEqual(events.map(\.delay), events.map(\.delay).sorted())
        XCTAssertTrue(events.contains { $0.bytes.first == 0xB5 })
        for event in events {
            XCTAssertEqual(event.bytes[0] & 15, 5)
            if event.bytes[0] & 0xF0 == 0x90 { held[event.bytes[1], default: 0] += 1 }
            if event.bytes[0] & 0xF0 == 0x80 { held[event.bytes[1], default: 0] -= 1 }
        }
        XCTAssertTrue(held.values.allSatisfy { $0 == 0 })
    }
}
