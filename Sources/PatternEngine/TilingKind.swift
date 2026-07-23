public enum SymmetryDocumentDomainID: UInt32, Codable, Sendable {
    case periodic = 0
    case finite = 1
}

public enum SymmetryPresetID: UInt32, CaseIterable, Codable, Sendable {
    case grid = 0
    case halfDrop = 1
    case brick = 2
    case mirrorX = 3
    case mirrorY = 4
    case mirrorXY = 5
    case rotational = 6
}

public typealias TilingKind = SymmetryPresetID
