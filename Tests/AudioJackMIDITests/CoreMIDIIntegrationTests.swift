import XCTest
import CoreMIDI
@testable import AudioJackMIDI

final class CoreMIDIIntegrationTests: XCTestCase {
    func testVirtualDestinationReceivesVariableSizePackets() throws {
        // Software-only loopback: this destination is not connected to any audio output.
        let received = expectation(description: "two MIDI packets received")
        received.expectedFulfillmentCount = 2
        let lock = NSLock()
        var captured: [[UInt8]] = []
        let destination = try MIDIVirtualPort(name: "AudioJack MIDI test \(UUID().uuidString)") { bytes, _ in
            lock.lock(); captured.append(bytes); lock.unlock()
            received.fulfill()
        }
        var client = MIDIClientRef(), port = MIDIPortRef()
        try check(MIDIClientCreateWithBlock("AudioJack test sender" as CFString, &client, nil), "Test MIDI client")
        defer { MIDIClientDispose(client) }
        try check(MIDIOutputPortCreate(client, "Test output" as CFString, &port), "Test output port")
        defer { MIDIPortDispose(port) }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { memory.deallocate() }
        let list = memory.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(list)
        let first: [UInt8] = [0x90, 60, 100]
        let second: [UInt8] = [0xF0, 0x7D] + [UInt8](repeating: 1, count: 300) + [0xF7]
        packet = MIDIPacketListAdd(list, 4096, packet, 1, first.count, first)
        _ = MIDIPacketListAdd(list, 4096, packet, 2, second.count, second)
        try check(MIDISend(port, destination.endpoint, list), "Send loopback packets")
        wait(for: [received], timeout: 3)
        lock.lock(); let result = captured; lock.unlock()
        XCTAssertEqual(result, [first, second])
        withExtendedLifetime(destination) {}
    }
}
