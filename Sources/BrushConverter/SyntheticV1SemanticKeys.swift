import Foundation

/// Closed semantic surface for the project-owned synthetic adapter.
///
/// This is deliberately small: it proves converter coverage and diagnostics
/// without baking any third-party format keys into the format-neutral IR.
public enum SyntheticV1SemanticKeys {
    public static let accumulation = "synthetic.v1.accumulation"
    public static let flow = "synthetic.v1.flow"
    public static let grain = "synthetic.v1.grain"
    public static let opacity = "synthetic.v1.opacity"
    public static let rotation = "synthetic.v1.rotation"
    public static let scatter = "synthetic.v1.scatter"
    public static let shape = "synthetic.v1.shape"
    public static let sizePressure = "synthetic.v1.size-pressure"
    public static let spacing = "synthetic.v1.spacing"
    public static let wet = "synthetic.v1.wet"

    public static let dry = [
        accumulation,
        flow,
        grain,
        opacity,
        rotation,
        scatter,
        shape,
        sizePressure,
        spacing,
    ]

    public static let all = dry + [wet]
}

public enum SyntheticV1MappingError: Error, Equatable, Sendable {
    case unsupportedSourceFormat(family: String, version: String?)
    case unsupportedParser(identifier: String, version: String)
    case unexpectedSettingNamespace(String)
    case missingSetting(String)
    case invalidSetting(key: String, reason: String)
    case missingResource(String)
    case unexpectedResource(String)
    case resourceRoleMismatch(
        resourceID: String,
        expected: ForeignBrushResourceRole,
        actual: ForeignBrushResourceRole
    )
    case unsupportedResource(resourceID: String, reason: String)
    case malformedResource(resourceID: String, reason: String)
}
