import Foundation

public enum ForeignBrushLimits {
    public static let maximumStringUTF8Bytes = 64 * 1_024
    public static let maximumLocationUTF8Bytes = 1_024
    public static let maximumMediaTypeUTF8Bytes = 255
    public static let maximumSettingsPerBrush = 4_096
    public static let maximumCurvePointsPerSetting = 1_024
    public static let maximumVectorComponents = 16
    public static let maximumResourcesPerBrush = 64
    public static let maximumDiagnosticsPerBrush = 4_096
    public static let maximumDiagnosticCodeUTF8Bytes = 256
    public static let maximumDiagnosticMessageUTF8Bytes = 4_096
    public static let maximumSourceImageDimension = 16_384
    public static let maximumCumulativeDecodedPixelsPerBrush = 268_435_456
    public static let maximumEncodedResourceBytes = 256 * 1_024 * 1_024
    public static let maximumCumulativeResourceBytes = 1_024 * 1_024 * 1_024
}

public enum ForeignBrushValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(UInt16)
    case empty(String)
    case stringTooLong(field: String, maximumUTF8Bytes: Int)
    case controlCharacter(String)
    case unsafeLocation(String)
    case invalidSemanticKey(String)
    case invalidDiagnosticCode(String)
    case invalidMediaType(String)
    case invalidSHA256(String)
    case countOutOfRange(field: String, actual: Int, maximum: Int)
    case unsorted(String)
    case duplicate(field: String, value: String)
    case nonFinite(String)
    case outOfRange(String)
    case domainMismatch(
        expected: ForeignBrushSettingDomain,
        actual: ForeignBrushSettingDomain
    )
    case unitMismatch(
        domain: ForeignBrushSettingDomain,
        unit: ForeignBrushSettingUnit
    )
    case danglingResourceReference(settingKey: String, resourceID: String)
    case resourceTableMismatch(missing: [String], unexpected: [String])
    case resourceByteCountMismatch(
        resourceID: String,
        expected: Int,
        actual: Int
    )
    case resourceHashMismatch(String)
    case cumulativeResourceBytesExceeded(maximum: Int)
    case cumulativeDecodedPixelsExceeded(maximum: Int)
}

enum ForeignBrushValidator {
    static func string(
        _ value: String,
        field: String,
        allowEmpty: Bool = false,
        maximumUTF8Bytes: Int = ForeignBrushLimits.maximumStringUTF8Bytes
    ) throws {
        if !allowEmpty && value.isEmpty {
            throw ForeignBrushValidationError.empty(field)
        }
        guard value.utf8.count <= maximumUTF8Bytes else {
            throw ForeignBrushValidationError.stringTooLong(
                field: field,
                maximumUTF8Bytes: maximumUTF8Bytes
            )
        }
        guard value.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw ForeignBrushValidationError.controlCharacter(field)
        }
    }

    static func optionalString(_ value: String?, field: String) throws {
        guard let value else { return }
        try string(value, field: field)
    }

    static func location(_ value: String, field: String) throws {
        try string(
            value,
            field: field,
            maximumUTF8Bytes: ForeignBrushLimits.maximumLocationUTF8Bytes
        )
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let driveQualified =
            value.utf8.count >= 2
            && value.utf8[value.utf8.index(after: value.utf8.startIndex)] == 58
        guard !value.hasPrefix("/"),
              !value.hasPrefix("\\"),
              !value.contains("\\"),
              !driveQualified,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ForeignBrushValidationError.unsafeLocation(field)
        }
    }

    static func sha256(_ value: String, field: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else {
            throw ForeignBrushValidationError.invalidSHA256(field)
        }
    }

    static func semanticKey(_ value: String) throws {
        try string(value, field: "setting.semanticKey")
        let bytes = Array(value.utf8)
        let allowed = bytes.allSatisfy {
            (97...122).contains($0)
                || (48...57).contains($0)
                || $0 == 46
                || $0 == 45
                || $0 == 95
                || $0 == 91
                || $0 == 93
                || $0 == 47
        }
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        let versionIndex = components.indices.dropFirst().first {
            let component = components[$0].utf8
            return component.first == 118
                && component.count > 1
                && component.dropFirst().allSatisfy {
                    (48...57).contains($0)
                }
        }
        guard allowed,
              bytes.first.map({ (97...122).contains($0) }) == true,
              components.count >= 3,
              components.allSatisfy({ !$0.isEmpty }),
              let versionIndex,
              versionIndex < components.index(before: components.endIndex)
        else {
            throw ForeignBrushValidationError.invalidSemanticKey(value)
        }
    }

    static func diagnosticCode(_ value: String) throws {
        try string(
            value,
            field: "diagnostic.code",
            maximumUTF8Bytes:
                ForeignBrushLimits.maximumDiagnosticCodeUTF8Bytes
        )
        let allowed = value.utf8.allSatisfy {
            (48...57).contains($0)
                || (65...90).contains($0)
                || (97...122).contains($0)
                || $0 == 46
                || $0 == 45
                || $0 == 95
        }
        guard allowed else {
            throw ForeignBrushValidationError.invalidDiagnosticCode(value)
        }
    }

    static func mediaType(_ value: String) throws {
        let bytes = Array(value.utf8)
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let allowedTokenByte: (UInt8) -> Bool = {
            (97...122).contains($0)
                || (48...57).contains($0)
                || [33, 35, 36, 38, 94, 95, 46, 43, 45].contains($0)
        }
        guard !bytes.isEmpty,
              bytes.count <= ForeignBrushLimits.maximumMediaTypeUTF8Bytes,
              components.count == 2,
              components.allSatisfy({
                  !$0.isEmpty && $0.utf8.allSatisfy(allowedTokenByte)
              })
        else {
            throw ForeignBrushValidationError.invalidMediaType(value)
        }
    }

    static func count(
        _ actual: Int,
        field: String,
        maximum: Int,
        minimum: Int = 0
    ) throws {
        guard (minimum...maximum).contains(actual) else {
            throw ForeignBrushValidationError.countOutOfRange(
                field: field,
                actual: actual,
                maximum: maximum
            )
        }
    }

    static func finite(_ value: Double, field: String) throws {
        guard value.isFinite else {
            throw ForeignBrushValidationError.nonFinite(field)
        }
    }

    static func sortedUnique<T>(
        _ values: [T],
        field: String,
        key: (T) -> String
    ) throws {
        let keys = values.map(key)
        guard keys == keys.sorted() else {
            throw ForeignBrushValidationError.unsorted(field)
        }
        for index in keys.indices.dropFirst()
        where keys[index - 1] == keys[index] {
            throw ForeignBrushValidationError.duplicate(
                field: field,
                value: keys[index]
            )
        }
    }
}
