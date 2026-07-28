import Foundation

enum ForeignPropertyListReader {
    static func parse(
        _ data: Data,
        limits: ForeignPropertyListLimits = .standard,
        budget: ForeignPropertyListBudget? = nil
    ) throws -> ForeignPropertyListGraph {
        let activeBudget = budget ?? ForeignPropertyListBudget(limits: limits)
        guard activeBudget.isCompatible(with: limits) else {
            throw ForeignPropertyListError.invalidLimits
        }
        guard data.count <= limits.maximumInputBytes else {
            throw ForeignPropertyListError.inputTooLarge(
                actual: data.count,
                maximum: limits.maximumInputBytes
            )
        }
        let source = data.startIndex == 0 ? data : Data(data)
        if source.starts(with: ForeignBinaryPropertyListReader.signature) {
            return try ForeignBinaryPropertyListReader(
                data: source,
                limits: limits,
                budget: activeBudget
            ).parse()
        }
        guard hasXMLSignature(source) else {
            throw ForeignPropertyListError.unsupportedSignature
        }
        return try ForeignXMLPropertyListReader.read(
            source,
            limits: limits,
            budget: activeBudget
        )
    }

    private static func hasXMLSignature(_ data: Data) -> Bool {
        var offset = 0
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            offset = 3
        }
        while offset < data.count {
            switch data[offset] {
            case 0x09, 0x0A, 0x0D, 0x20:
                offset += 1
            default:
                let remaining = data[offset...]
                return remaining.starts(with: Data("<?xml".utf8))
                    || remaining.starts(with: Data("<!DOCTYPE".utf8))
                    || remaining.starts(with: Data("<plist".utf8))
            }
        }
        return false
    }
}
