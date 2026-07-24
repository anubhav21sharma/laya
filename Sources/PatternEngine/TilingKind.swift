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
    case squareRotation = 7
    case squareKaleidoscope = 8
    case hexagons = 9
    case rotation3 = 10
    case rotation6 = 11
    case kaleidoscope60 = 12
    case kaleidoscope30 = 13
    case plainCanvas = 14
    case radialMirror = 15
    case radialRotation = 16
    case radialMandala = 17
}

public typealias TilingKind = SymmetryPresetID

public extension SymmetryPresetID {
    static let periodicCases: [Self] = allCases.filter(\.isPeriodic)

    var isPeriodic: Bool {
        rawValue <= SymmetryPresetID.kaleidoscope30.rawValue
    }
}
