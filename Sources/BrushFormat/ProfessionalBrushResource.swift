import Foundation
import PatternEngine

public enum ProfessionalBrushResourceID:
    String, CaseIterable, Codable, Sendable
{
    case technicalInkTip = "builtin.shape.technical-nib"
    case graphiteTip = "builtin.shape.graphite-tip"
    case graphitePaperGrain = "builtin.grain.graphite-paper"
    case charcoalTip = "builtin.shape.charcoal-tip"
    case charcoalFineGrain = "builtin.grain.charcoal-fine-paper"
    case charcoalCoarseGrain = "builtin.grain.charcoal"
    case chiselTip = "builtin.shape.marker-chisel"
}

public struct ProfessionalBrushResourceDescriptor:
    Equatable, Sendable
{
    public let id: ProfessionalBrushResourceID
    public let kind: BrushResourceKind
    public let fileName: String
    public let dimension: Int
    public let sha256: String
    public let intendedMaximumDiameter: Int

    public var byteCount: Int { dimension * dimension }
}

public enum ProfessionalBrushResourceError: Error, Equatable, Sendable {
    case unknownIdentifier(String)
    case missingResource(String)
    case byteCountMismatch(id: String, expected: Int, actual: Int)
    case contentHashMismatch(id: String)
}

public enum ProfessionalBrushResources {
    public static let descriptors: [ProfessionalBrushResourceDescriptor] = [
        descriptor(
            .technicalInkTip,
            kind: .shape,
            fileName: "technical-ink-tip.r8",
            dimension: 128,
            sha256: "9d7f3309b05ca4de7d998e10c1984f4e16f958e2cba2dc6c328c573b9ee47ff9",
            intendedMaximumDiameter: 512
        ),
        descriptor(
            .graphiteTip,
            kind: .shape,
            fileName: "graphite-tip.r8",
            dimension: 128,
            sha256: "fd896137448eb5582b3958eeb56f2a39c453e01a041f4cc7d12dc1dda84c0f79",
            intendedMaximumDiameter: 384
        ),
        descriptor(
            .graphitePaperGrain,
            kind: .grain,
            fileName: "graphite-paper-grain.r8",
            dimension: 256,
            sha256: "519372f74c7df9047d5773f0373f6e6ec6a9db3037d78e03fd710450d2125b38",
            intendedMaximumDiameter: 768
        ),
        descriptor(
            .charcoalTip,
            kind: .shape,
            fileName: "charcoal-tip.r8",
            dimension: 128,
            sha256: "2a971cb99a62679fe00dd13bea9320c166100f84456a23fb6c82642872de3e69",
            intendedMaximumDiameter: 512
        ),
        descriptor(
            .charcoalFineGrain,
            kind: .grain,
            fileName: "charcoal-fine-grain.r8",
            dimension: 256,
            sha256: "da3803d73034a64619886d1bfcd3d710a46995d7b827cc0a0a6c9338e1886bff",
            intendedMaximumDiameter: 1_024
        ),
        descriptor(
            .charcoalCoarseGrain,
            kind: .grain,
            fileName: "charcoal-coarse-grain.r8",
            dimension: 256,
            sha256: "cadd1bc2f935d0a52e9ddaaddd11e5fc2831f833c51c6963e492ac75439a9edb",
            intendedMaximumDiameter: 1_024
        ),
        descriptor(
            .chiselTip,
            kind: .shape,
            fileName: "chisel-tip.r8",
            dimension: 128,
            sha256: "3dabef4087df68a0f0ecf4d588eebc9f485fe407d542f85fe68cfd8bd5dae643",
            intendedMaximumDiameter: 512
        ),
    ]

    public static func descriptor(
        for identifier: String
    ) throws -> ProfessionalBrushResourceDescriptor {
        guard let result = descriptors.first(where: {
            $0.id.rawValue == identifier
        }) else {
            throw ProfessionalBrushResourceError.unknownIdentifier(identifier)
        }
        return result
    }

    public static func data(
        for id: ProfessionalBrushResourceID
    ) throws -> Data {
        let resource = try descriptor(for: id.rawValue)
        guard let url = Bundle.module.url(
            forResource: resource.fileName,
            withExtension: nil
        ), let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            throw ProfessionalBrushResourceError.missingResource(
                resource.fileName
            )
        }
        guard data.count == resource.byteCount else {
            throw ProfessionalBrushResourceError.byteCountMismatch(
                id: id.rawValue,
                expected: resource.byteCount,
                actual: data.count
            )
        }
        guard BrushContentHash.sha256Hex(of: data) == resource.sha256 else {
            throw ProfessionalBrushResourceError.contentHashMismatch(
                id: id.rawValue
            )
        }
        return data
    }

    private static func descriptor(
        _ id: ProfessionalBrushResourceID,
        kind: BrushResourceKind,
        fileName: String,
        dimension: Int,
        sha256: String,
        intendedMaximumDiameter: Int
    ) -> ProfessionalBrushResourceDescriptor {
        ProfessionalBrushResourceDescriptor(
            id: id,
            kind: kind,
            fileName: fileName,
            dimension: dimension,
            sha256: sha256,
            intendedMaximumDiameter: intendedMaximumDiameter
        )
    }
}
