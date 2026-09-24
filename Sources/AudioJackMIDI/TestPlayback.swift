import Foundation

/// Tracks accepted generator messages, including ones still waiting in the audio FIFO.
/// Restart must retain that FIFO: an accepted Note On must precede its cleanup Note Off.
/// All access is on Transport.queue; this is not used by the realtime audio callback.
final class TestPlayback {
    private(set) var generation = 0
    private var outstanding: [Int: Int] = [:]
    private var bentChannels: Set<UInt8> = []

    @discardableResult
    func deliver(_ bytes: [UInt8], token: Int, send: ([UInt8]) -> Bool) -> Bool {
        guard token == generation, send(bytes) else { return false }
        guard bytes.count == 3 else { return true }
        let channel = bytes[0] & 0x0F
        let key = Int(channel) * 128 + Int(bytes[1])
        switch bytes[0] & 0xF0 {
        case 0x90 where bytes[2] > 0:
            outstanding[key, default: 0] += 1
        case 0x80, 0x90:
            let count = outstanding[key, default: 0]
            if count > 1 { outstanding[key] = count - 1 } else { outstanding.removeValue(forKey: key) }
        case 0xE0:
            if bytes[1] == 0 && bytes[2] == 64 { bentChannels.remove(channel) }
            else { bentChannels.insert(channel) }
        default: break
        }
        return true
    }

    /// Cancel future callbacks, then append one Note Off per unmatched Note On.
    /// Keep counts if the FIFO rejects cleanup; callers must not start a replacement.
    @discardableResult
    func cancel(send: ([UInt8]) -> Bool) -> Bool {
        generation += 1
        var cleanup: [UInt8] = []
        for key in outstanding.keys.sorted() {
            for _ in 0..<outstanding[key, default: 0] {
                cleanup += [0x80 | UInt8(key / 128), UInt8(key % 128), 0]
            }
        }
        for channel in bentChannels.sorted() { cleanup += [0xE0 | channel, 0, 64] }
        guard cleanup.isEmpty || send(cleanup) else { return false }
        outstanding.removeAll(); bentChannels.removeAll()
        return true
    }

    /// Used when the audio FIFO is deliberately discarded (emergency Panic / device loss).
    func discard() {
        generation += 1; outstanding.removeAll(); bentChannels.removeAll()
    }
}
