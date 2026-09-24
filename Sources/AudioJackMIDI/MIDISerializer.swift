import Foundation
import TransportCore

/// Incremental MIDI 1.0 parser. Emits explicit channel status even for running status.
/// Real-time bytes never disturb a pending message and retain their position in it.
final class MIDISerializer {
    var velocityZeroNoteOff = false
    private var running: UInt8 = 0
    private var status: UInt8 = 0
    private var position = 0
    private var length = 0
    private var sysex = false
    private var convertOff = false

    func reset() { running = 0; status = 0; position = 0; length = 0; sysex = false }

    func process(_ bytes: [UInt8], at time: UInt64) -> [AJByte] {
        var result: [AJByte] = []
        func emit(_ value: UInt8, end: Bool = false) {
            result.append(AJByte(byte: value, messageEnd: end ? 1 : 0, hostTime: time))
        }
        func begin(_ value: UInt8) {
            status = value; position = 0
            length = Self.dataLength(value)
            convertOff = velocityZeroNoteOff && value & 0xF0 == 0x80
            emit(convertOff ? (0x90 | (value & 0x0F)) : value, end: length == 0)
        }
        for byte in bytes {
            if byte >= 0xF8 {
                emit(byte, end: status == 0 && !sysex)
                continue
            }
            if byte & 0x80 != 0 {
                if byte == 0xF7 {
                    if sysex { emit(byte, end: true) }
                    sysex = false; running = 0; status = 0
                    continue
                }
                sysex = false
                if byte == 0xF0 {
                    running = 0; status = 0; sysex = true; emit(byte)
                } else {
                    running = byte < 0xF0 ? byte : 0
                    begin(byte)
                    if length == 0 { status = 0 }
                }
            } else if sysex {
                emit(byte)
            } else {
                if status == 0 {
                    guard running != 0 else { continue } // Stray data has no meaningful UART message.
                    begin(running)
                }
                position += 1
                emit(convertOff && position == 2 ? 0 : byte, end: position == length)
                if position == length { status = 0 }
            }
        }
        return result
    }
    private static func dataLength(_ status: UInt8) -> Int {
        if status < 0xF0 { return status & 0xE0 == 0xC0 ? 1 : 2 }
        switch status { case 0xF1, 0xF3: return 1; case 0xF2: return 2; default: return 0 }
    }
}
