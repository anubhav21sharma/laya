import Foundation

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { value in
        var result = UInt32(value)
        for _ in 0..<8 {
            result = (result & 1) == 0
                ? result >> 1
                : 0xEDB8_8320 ^ (result >> 1)
        }
        return result
    }

    static func checksum(_ data: Data) -> UInt32 {
        checksum(data, range: 0..<data.count)
    }

    static func checksum(_ data: Data, range: Range<Int>) -> UInt32 {
        var result = UInt32.max
        for index in range {
            let tableIndex = Int((result ^ UInt32(data[index])) & 0xFF)
            result = table[tableIndex] ^ (result >> 8)
        }
        return result ^ UInt32.max
    }
}
