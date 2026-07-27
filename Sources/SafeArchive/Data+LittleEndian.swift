import Foundation

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    func uint16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else {
            throw SafeArchiveError.malformedArchive
        }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else {
            throw SafeArchiveError.malformedArchive
        }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func uint64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= count - 8 else {
            throw SafeArchiveError.malformedArchive
        }
        return UInt64(self[offset])
            | UInt64(self[offset + 1]) << 8
            | UInt64(self[offset + 2]) << 16
            | UInt64(self[offset + 3]) << 24
            | UInt64(self[offset + 4]) << 32
            | UInt64(self[offset + 5]) << 40
            | UInt64(self[offset + 6]) << 48
            | UInt64(self[offset + 7]) << 56
    }
}
