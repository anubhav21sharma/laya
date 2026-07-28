import Foundation

public enum ForeignBrushCoding {
    public static func encode(_ ir: ForeignBrushIR) throws -> Data {
        try encoder().encode(ir)
    }

    public static func decodeIR(_ data: Data) throws -> ForeignBrushIR {
        try JSONDecoder().decode(ForeignBrushIR.self, from: data)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
