import Foundation

enum ProcreateArchiveValueDecoder {
    static func decode(
        _ identifier: ForeignPropertyListObjectID,
        from view: BoundedKeyedArchiveView
    ) throws -> ForeignBrushSettingValue? {
        switch try view.resolvedNode(at: identifier) {
        case let .boolean(value):
            .boolean(value)
        case let .integer(value):
            .integer(value)
        case let .real(value):
            .scalar(value == 0 ? 0 : value)
        case let .string(value):
            value == "$null" ? .null : .token(value)
        case .dictionary, .array, .data, .date, .uid:
            nil
        }
    }
}
