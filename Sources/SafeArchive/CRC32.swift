import Foundation

package enum CRC32 {
    package static let table: [UInt32] = (0..<256).map { value in
        var result = UInt32(value)
        for _ in 0..<8 {
            result = (result & 1) == 0
                ? result >> 1
                : 0xEDB8_8320 ^ (result >> 1)
        }
        return result
    }

    package static func checksum(_ data: Data) -> UInt32 {
        checksum(data, range: 0..<data.count)
    }

    package static func checksum(_ data: Data, range: Range<Int>) -> UInt32 {
        var accumulator = CRC32Accumulator()
        accumulator.update(data[range])
        return accumulator.checksum
    }
}

package struct CRC32Accumulator {
    private var result = UInt32.max

    package init() {}

    package mutating func update<Bytes: Sequence>(_ bytes: Bytes)
    where Bytes.Element == UInt8 {
        for byte in bytes {
            let tableIndex = Int((result ^ UInt32(byte)) & 0xFF)
            result = CRC32.table[tableIndex] ^ (result >> 8)
        }
    }

    package var checksum: UInt32 { result ^ UInt32.max }
}
