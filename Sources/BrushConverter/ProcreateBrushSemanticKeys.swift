import Foundation

/// Stable keys emitted by the structural Procreate adapters.
///
/// Resource keys describe independently observed archive entries. Raw keys
/// record only that an unverified source field exists; they deliberately do
/// not claim a unit, formula, or native rendering meaning.
public enum ProcreateBrushSemanticKeys {
    public static let shape = "procreate.classic.v1.shape"
    public static let grain = "procreate.classic.v1.grain"
    public static let paintSize = "procreate.classic.v1.placement.paint-size"
    public static let plotSpacing = "procreate.classic.v1.placement.plot-spacing"
    public static let paintOpacity = "procreate.classic.v1.paint.opacity"
    public static let paintFlow = "procreate.classic.v1.paint.flow"
    public static let pressureSize = "procreate.classic.v1.dynamics.pressure-size"
    public static let pressureOpacity = "procreate.classic.v1.dynamics.pressure-opacity"
    public static let tiltSize = "procreate.classic.v1.dynamics.tilt-size"
    public static let tiltShapeRoundness = "procreate.classic.v1.dynamics.tilt-shape-roundness"
    public static let textureScale = "procreate.classic.v1.grain.texture-scale"
    public static let textureMovement = "procreate.classic.v1.grain.texture-movement"
    public static let bundledShapePath = "procreate.classic.v1.resource.bundled-shape-path"
    public static let bundledGrainPath = "procreate.classic.v1.resource.bundled-grain-path"
    public static let dualBlendMode = "procreate.classic.v1.composition.dual-blend-mode"
    public static let shapeScatter = "procreate.classic.v1.placement.shape-scatter"
    public static let shapeRotation = "procreate.classic.v1.placement.shape-rotation"
    public static let grainDepth = "procreate.classic.v1.grain.depth"
    public static let grainDepthMinimum = "procreate.classic.v1.grain.depth-minimum"

    static let rawPrefix = "procreate.classic.v1.raw."

    static func verified(_ sourceKey: String) -> String? {
        switch sourceKey {
        case "paintSize": paintSize
        case "plotSpacing": plotSpacing
        case "paintOpacity": paintOpacity
        case "paintFlow": paintFlow
        case "dynamicsPressureSize": pressureSize
        case "dynamicsPressureOpacity": pressureOpacity
        case "dynamicsTiltSize": tiltSize
        case "dynamicsTiltShapeRoundness": tiltShapeRoundness
        case "textureScale": textureScale
        case "textureMovement": textureMovement
        case "bundledShapePath": bundledShapePath
        case "bundledGrainPath": bundledGrainPath
        case "dualBlendMode": dualBlendMode
        case "shapeScatter": shapeScatter
        case "shapeRotation": shapeRotation
        case "grainDepth": grainDepth
        case "grainDepthMinimum": grainDepthMinimum
        default: nil
        }
    }

    static func raw(_ sourceKey: String) -> String {
        var slug = sourceKey.lowercased().utf8.map { byte -> UInt8 in
            switch byte {
            case 97 ... 122, 48 ... 57:
                byte
            default:
                45
            }
        }
        while slug.first == 45 {
            slug.removeFirst()
        }
        while slug.last == 45 {
            slug.removeLast()
        }
        let compact = String(decoding: slug, as: UTF8.self)
        let stem = compact.isEmpty ? "field" : compact
        let digest = ForeignBrushDocument.contentSHA256(Data(sourceKey.utf8))
        return "\(rawPrefix)\(stem.prefix(48))-\(digest.prefix(12))"
    }
}
