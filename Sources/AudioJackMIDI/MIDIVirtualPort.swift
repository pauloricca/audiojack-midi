import CoreMIDI
import Foundation

final class MIDIVirtualPort {
    private var client = MIDIClientRef()
    private(set) var endpoint = MIDIEndpointRef()
    init(name: String = "AudioJack MIDI Out", receive: @escaping ([UInt8], UInt64) -> Void) throws {
        try check(MIDIClientCreateWithBlock("AudioJack MIDI" as CFString, &client, nil), "Create MIDI client")
        let result = MIDIDestinationCreateWithBlock(client, name as CFString, &endpoint) { packets, _ in
            // MIDIPacketNext handles variable packet sizes; copy before the callback returns.
            do {
                let offset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet)!
                var packet = UnsafeRawPointer(packets).advanced(by: offset).assumingMemoryBound(to: MIDIPacket.self)
                for _ in 0..<packets.pointee.numPackets {
                    let count = Int(packet.pointee.length)
                    let timestamp = packet.pointee.timeStamp
                    let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
                    let data = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
                    receive(Array(UnsafeBufferPointer(start: data, count: count)), timestamp)
                    packet = UnsafePointer(MIDIPacketNext(packet))
                }
            }
        }
        if result != noErr { MIDIClientDispose(client); client = 0; try check(result, "Create virtual MIDI destination") }
    }
    deinit {
        if endpoint != 0 { MIDIEndpointDispose(endpoint) }
        if client != 0 { MIDIClientDispose(client) }
    }
}
