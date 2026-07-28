import Foundation

enum ProcreateTestFixtureFactory {
    struct Entry {
        let path: String
        let data: Data
    }

    static let png: Data = {
        guard let data = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        else {
            preconditionFailure("Project-owned PNG fixture is invalid.")
        }
        return data
    }()

    static func brushArchive(
        name: String,
        author: String? = nil,
        unverifiedFields: [String: Double] = [:]
    ) throws -> Data {
        try NSKeyedArchiver.archivedData(
            withRootObject: OwnedProcreateBrushArchive(
                name: name,
                author: author,
                unverifiedFields: unverifiedFields
            ),
            requiringSecureCoding: true
        )
    }

    static func brushSetManifest(_ members: [String]) -> Data {
        let values = members
            .map { "      <string>\($0)</string>" }
            .joined(separator: "\n")
        return Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
              <dict>
                <key>brushes</key>
                <array>
            \(values)
                </array>
              </dict>
            </plist>
            """.utf8
        )
    }

    static func zip(_ entries: [Entry]) -> Data {
        var output = Data()
        var central = [CentralEntry]()
        for entry in entries {
            let path = Data(entry.path.utf8)
            let checksum = crc32(entry.data)
            let localOffset = UInt32(output.count)
            appendUInt32(0x0403_4B50, to: &output)
            appendUInt16(10, to: &output)
            appendUInt16(0x0800, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt32(checksum, to: &output)
            appendUInt32(UInt32(entry.data.count), to: &output)
            appendUInt32(UInt32(entry.data.count), to: &output)
            appendUInt16(UInt16(path.count), to: &output)
            appendUInt16(0, to: &output)
            output.append(path)
            output.append(entry.data)
            central.append(CentralEntry(
                path: path,
                checksum: checksum,
                byteCount: UInt32(entry.data.count),
                localOffset: localOffset
            ))
        }
        let centralOffset = UInt32(output.count)
        for entry in central {
            appendUInt32(0x0201_4B50, to: &output)
            appendUInt16(0x0314, to: &output)
            appendUInt16(10, to: &output)
            appendUInt16(0x0800, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt32(entry.checksum, to: &output)
            appendUInt32(entry.byteCount, to: &output)
            appendUInt32(entry.byteCount, to: &output)
            appendUInt16(UInt16(entry.path.count), to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt32(0x81A4_0000, to: &output)
            appendUInt32(entry.localOffset, to: &output)
            output.append(entry.path)
        }
        let centralSize = UInt32(output.count) - centralOffset
        appendUInt32(0x0605_4B50, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(UInt16(entries.count), to: &output)
        appendUInt16(UInt16(entries.count), to: &output)
        appendUInt32(centralSize, to: &output)
        appendUInt32(centralOffset, to: &output)
        appendUInt16(0, to: &output)
        return output
    }
}

@objc(LayaOwnedProcreateBrushArchiveFixture)
private final class OwnedProcreateBrushArchive: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true

    private let name: String
    private let author: String?
    private let unverifiedFields: [String: Double]

    init(
        name: String,
        author: String?,
        unverifiedFields: [String: Double]
    ) {
        self.name = name
        self.author = author
        self.unverifiedFields = unverifiedFields
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "name")
        if let author {
            coder.encode(author, forKey: "authorName")
        }
        for key in unverifiedFields.keys.sorted() {
            guard let value = unverifiedFields[key] else {
                preconditionFailure("Sorted fixture key disappeared.")
            }
            coder.encode(value, forKey: key)
        }
    }
}

private struct CentralEntry {
    let path: Data
    let checksum: UInt32
    let byteCount: UInt32
    let localOffset: UInt32
}

private func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func crc32(_ data: Data) -> UInt32 {
    var result = UInt32.max
    for byte in data {
        result ^= UInt32(byte)
        for _ in 0 ..< 8 {
            result = result & 1 == 0
                ? result >> 1
                : 0xEDB8_8320 ^ (result >> 1)
        }
    }
    return result ^ UInt32.max
}
