import Foundation

/// Stable keys emitted by the structural Procreate adapters.
///
/// Resource keys describe independently observed archive entries. Raw keys
/// record only that an unverified source field exists; they deliberately do
/// not claim a unit, formula, or native rendering meaning.
public enum ProcreateBrushSemanticKeys {
    public static let shape = "procreate.classic.v1.shape"
    public static let grain = "procreate.classic.v1.grain"

    static let rawPrefix = "procreate.classic.v1.raw."

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
