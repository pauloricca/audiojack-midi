import XCTest
import TransportCore
@testable import AudioJackMIDI

final class TestPlaybackTests: XCTestCase {
    func testTwoOnsNeedTwoOffsWithSeparateChannelCounts() {
        let playback = TestPlayback()
        for bytes: [UInt8] in [[0x90, 60, 100], [0x90, 60, 110], [0x91, 60, 100]] {
            playback.deliver(bytes, token: 0) { _ in true }
        }
        var cleanup: [UInt8] = []
        XCTAssertTrue(playback.cancel { cleanup = $0; return true })
        XCTAssertEqual(cleanup, [0x80, 60, 0, 0x80, 60, 0, 0x81, 60, 0])
    }

    func testOneOffOnlyReleasesOneVoiceIncludingVelocityZero() {
        for off: [UInt8] in [[0x82, 65, 0], [0x92, 65, 0]] {
            let playback = TestPlayback()
            playback.deliver([0x92, 65, 100], token: 0) { _ in true }
            playback.deliver([0x92, 65, 100], token: 0) { _ in true }
            playback.deliver(off, token: 0) { _ in true }
            var cleanup: [UInt8] = []
            playback.cancel { cleanup = $0; return true }
            XCTAssertEqual(cleanup, [0x82, 65, 0])
        }
    }

    func testRapidSingleC4RestartsPreserveQueuedOffsAndRejectOldCallbacks() {
        let playback = TestPlayback()
        let parser = MIDISerializer()
        let renderer = aj_create(96000, 96000)!
        defer { aj_destroy(renderer) }
        var submitted: [UInt8] = []
        func send(_ bytes: [UInt8]) -> Bool {
            let output = parser.process(bytes, at: 0)
            guard aj_enqueue(renderer, output, UInt32(output.count)) else { return false }
            submitted += bytes
            return true
        }
        // No audio has rendered yet: restart must not discard any accepted messages.
        for _ in 0..<20 {
            let old = playback.generation
            XCTAssertTrue(playback.deliver([0x90, 60, 100], token: old, send: send))
            XCTAssertTrue(playback.cancel(send: send))
            XCTAssertFalse(playback.deliver([0x80, 60, 0], token: old, send: send))
        }
        // A normally queued Note Off needs no extra cleanup, but must survive restart.
        playback.deliver([0x90, 60, 100], token: playback.generation, send: send)
        playback.deliver([0x80, 60, 0], token: playback.generation, send: send)
        playback.cancel(send: send)
        let expected = Array(repeating: [UInt8](arrayLiteral: 0x90, 60, 100, 0x80, 60, 0), count: 21).flatMap { $0 }
        XCTAssertEqual(submitted, expected)
        var left = [Float](repeating: 0, count: 5000), right = left
        aj_render(renderer, &left, &right, 5000, 0)
        let decoded: [UInt8] = (0..<expected.count).map { index in
            var byte: UInt8 = 0
            for bit in 0..<8 {
                let sample = Int((Double(index) * 30.72).rounded()) + (bit + 1) * 3 + 1
                if left[sample] == 0 { byte |= 1 << bit }
            }
            return byte
        }
        XCTAssertEqual(decoded, expected)
    }

    func testScaleRestartAtEveryEventBoundaryBalancesAllNotes() {
        let scale = TestPattern.scale.events(channel: 0)
        for cutoff in 0...scale.count {
            let playback = TestPlayback()
            var balance: [UInt8: Int] = [:]
            func send(_ bytes: [UInt8]) -> Bool {
                for i in stride(from: 0, to: bytes.count, by: 3) {
                    let delta = bytes[i] & 0xF0 == 0x90 && bytes[i + 2] > 0 ? 1 : -1
                    balance[bytes[i + 1], default: 0] += delta
                    XCTAssertGreaterThanOrEqual(balance[bytes[i + 1], default: 0], 0)
                }
                return true
            }
            for event in scale.prefix(cutoff) { playback.deliver(event.bytes, token: 0, send: send) }
            playback.cancel(send: send)
            XCTAssertTrue(balance.values.allSatisfy { $0 == 0 })
            for event in scale { playback.deliver(event.bytes, token: playback.generation, send: send) }
            for event in scale.dropFirst(cutoff) {
                XCTAssertFalse(playback.deliver(event.bytes, token: 0, send: send))
            }
            XCTAssertTrue(balance.values.allSatisfy { $0 == 0 })
        }
    }

    func testFailedEnqueueDoesNotInventVoicesAndCleanupCanBeRetried() {
        let playback = TestPlayback()
        XCTAssertFalse(playback.deliver([0x90, 60, 100], token: 0) { _ in false })
        playback.deliver([0x90, 64, 100], token: 0) { _ in true }
        XCTAssertFalse(playback.cancel { _ in false })
        var cleanup: [UInt8] = []
        XCTAssertTrue(playback.cancel { cleanup = $0; return true })
        XCTAssertEqual(cleanup, [0x80, 64, 0])
    }

    func testRestartAlsoRestoresInterruptedPitchBend() {
        let playback = TestPlayback()
        playback.deliver([0xE3, 0, 100], token: 0) { _ in true }
        var cleanup: [UInt8] = []
        playback.cancel { cleanup = $0; return true }
        XCTAssertEqual(cleanup, [0xE3, 0, 64])
    }
}
