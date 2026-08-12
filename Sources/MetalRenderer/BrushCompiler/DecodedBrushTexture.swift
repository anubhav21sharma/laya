import BrushFormat
import Foundation
import PatternEngine

public enum BrushCompilationDiagnostic: Equatable, Sendable {
    case resourceResampled(
        id: String,
        sourceWidth: Int,
        sourceHeight: Int,
        workingWidth: Int,
        workingHeight: Int
    )
}

public struct DecodedBrushTexture: Equatable, Sendable {
    public let resourceID: String
    public let kind: BrushResourceKind
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let workingWidth: Int
    public let workingHeight: Int
    public let mipLevels: [Data]
    public let residentByteCount: Int
    public let wasResampled: Bool
    public let tipSupport: BrushTipAssetSupport?

    public var diagnostics: [BrushCompilationDiagnostic] {
        guard wasResampled else { return [] }
        return [
            .resourceResampled(
                id: resourceID,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                workingWidth: workingWidth,
                workingHeight: workingHeight
            ),
        ]
    }

    init(
        resourceID: String,
        kind: BrushResourceKind,
        sourceWidth: Int,
        sourceHeight: Int,
        workingWidth: Int,
        workingHeight: Int,
        mipLevels: [Data],
        residentByteCount: Int,
        wasResampled: Bool,
        tipSupport: BrushTipAssetSupport? = nil
    ) {
        self.resourceID = resourceID
        self.kind = kind
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.workingWidth = workingWidth
        self.workingHeight = workingHeight
        self.mipLevels = mipLevels
        self.residentByteCount = residentByteCount
        self.wasResampled = wasResampled
        self.tipSupport = tipSupport
    }
}
