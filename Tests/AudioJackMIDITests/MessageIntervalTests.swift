import XCTest
import TransportCore
@testable import AudioJackMIDI

final class MessageIntervalTests: XCTestCase {
    private func render(_ r: OpaquePointer, _ frames: Int, host: UInt64 = 0) -> [Float] {
        var left = [Float](repeating: 0, count: frames), right = left
        aj_render(r, &left, &right, UInt32(frames), host)
        return left
    }
    private func enqueue(_ r: OpaquePointer, _ bytes: [UInt8], time: UInt64 = 0) {
        let entries = MIDISerializer().process(bytes, at: time)
        XCTAssertTrue(aj_enqueue(r, entries, UInt32(entries.count)))
    }
    private func isolatedWave(_ bytes: [UInt8], rate: UInt32) -> [Float] {
        let r = aj_create(rate, Double(rate))!
        defer { aj_destroy(r) }
        enqueue(r, bytes)
        return render(r, Int((Double(bytes.count) * Double(rate) / 3125).rounded()))
    }

    func testStartToStartSpacingPreservesEveryByteAndRespectsIdleBits() {
        let messages: [[UInt8]] = [[0xB0, 1, 4], [0x90, 60, 100], [0xC0, 7], [0x80, 60, 0]]
        for rate: UInt32 in [96000, 192000] {
            for ms in [5.0, 25.125] {
                let r = aj_create(rate, Double(rate))!
                defer { aj_destroy(r) }
                aj_set_message_interval(r, ms)
                aj_configure(r, 0.9, true, 4)
                enqueue(r, messages.flatMap { $0 })
                var expected: [Float] = []
                for message in messages {
                    let wave = isolatedWave(message, rate: rate)
                    // UART duration + four idle bits competes with the interval;
                    // it is not added to the configured start-to-start spacing.
                    let withIdle = Int((Double(message.count * 10 + 4) * Double(rate) / 31250).rounded())
                    let period = max(Int(ceil(ms * Double(rate) / 1000)), withIdle)
                    expected += wave + Array(repeating: 0, count: period - wave.count)
                }
                XCTAssertEqual(render(r, expected.count), expected, "rate=\(rate), ms=\(ms)")
                XCTAssertEqual(aj_transmitted(r), 11)
            }
        }
    }

    func testIntervalShorterThanWireDurationLeavesContinuousWaveformUnchanged() {
        for rate: UInt32 in [96000, 192000] {
            let a = aj_create(rate, Double(rate))!, b = aj_create(rate, Double(rate))!
            defer { aj_destroy(a); aj_destroy(b) }
            for r in [a, b] {
                aj_configure(r, 0.9, true, 4)
                enqueue(r, [0x90, 60, 100, 0xC0, 7, 0x80, 60, 0])
            }
            aj_set_message_interval(b, 0.5)
            // No actual idle beyond the existing four bits: the fractional clock
            // continues across messages, so compare with the continuous renderer.
            XCTAssertEqual(render(a, 1000), render(b, 1000))
        }
    }

    func testSpacingSurvivesBufferSplitsAndEmptyQueueWithoutExtraDelay() {
        let a = aj_create(96000, 96000)!, b = aj_create(96000, 96000)!
        defer { aj_destroy(a); aj_destroy(b) }
        for r in [a, b] {
            aj_set_message_interval(r, 5)
            enqueue(r, [0xB0, 1, 0, 0xB0, 1, 4])
        }
        let whole = render(a, 1000)
        var split: [Float] = []
        for count in [1, 30, 100, 7, 342, 520] {
            split += render(b, count, host: UInt64(split.count))
        }
        XCTAssertEqual(split, whole)
        enqueue(b, [0x90, 60, 100], time: 1200)
        let late = render(b, 300, host: 1000)
        XCTAssertTrue(late.prefix(200).allSatisfy { $0 == 0 })
        XCTAssertEqual(late[200], -0.9) // Existing silence counts toward the interval.
    }

    func testLiveChangesAndZeroDisableTheWait() {
        let r = aj_create(96000, 96000)!
        defer { aj_destroy(r) }
        aj_set_message_interval(r, 60000)
        enqueue(r, [0x90, 60, 100, 0x80, 60, 0])
        _ = render(r, 1000)
        XCTAssertEqual(aj_transmitted(r), 3)
        aj_set_message_interval(r, 25)
        let wait = render(r, 1401, host: 1000)
        XCTAssertTrue(wait.prefix(1400).allSatisfy { $0 == 0 })
        XCTAssertEqual(wait[1400], -0.9)
        _ = render(r, 100, host: 2401)
        enqueue(r, [0xB0, 1, 0])
        aj_set_message_interval(r, 0)
        XCTAssertEqual(render(r, 1, host: 2501)[0], -0.9)
    }

    func testFragmentedMessageAndInterleavedRealtimeAreNotSplitByPacing() {
        let r = aj_create(96000, 96000)!
        defer { aj_destroy(r) }
        aj_set_message_interval(r, 5)
        let parser = MIDISerializer()
        for bytes: [UInt8] in [[0x90, 60], [0xF8, 100], [0x80, 60, 0]] {
            let entries = parser.process(bytes, at: 0)
            XCTAssertTrue(aj_enqueue(r, entries, UInt32(entries.count)))
        }
        let first = isolatedWave([0x90, 60, 0xF8, 100], rate: 96000)
        let second = isolatedWave([0x80, 60, 0], rate: 96000)
        let wave = render(r, 600)
        XCTAssertEqual(Array(wave.prefix(first.count)), first)
        XCTAssertTrue(wave[first.count..<480].allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(wave[480..<(480 + second.count)]), second)
    }

    func testPanicDiscardsFutureTrafficButFinishesAll48PacedMessages() {
        let r = aj_create(96000, 96000)!
        defer { aj_destroy(r) }
        aj_set_message_interval(r, 25)
        enqueue(r, [0x90, 60, 100], time: 99999999)
        aj_panic(r)
        XCTAssertTrue(aj_panic_pending(r))
        let early = render(r, 96000)
        XCTAssertTrue(aj_panic_pending(r)) // Stop must not use the old 300 ms timeout.
        let wave = early + render(r, 20000, host: 96000)
        XCTAssertFalse(aj_panic_pending(r))
        XCTAssertEqual(aj_transmitted(r), 144)
        XCTAssertEqual(aj_pending(r), 0)
        for index in 0..<48 {
            let channel = UInt8(index / 3)
            let messages: [[UInt8]] = [[0xB0 | channel, 123, 0], [0xB0 | channel, 120, 0], [0xE0 | channel, 0, 64]]
            let expected = isolatedWave(messages[index % 3], rate: 96000)
            let start = index * 2400
            XCTAssertEqual(Array(wave[start..<(start + expected.count)]), expected)
        }
    }
}
