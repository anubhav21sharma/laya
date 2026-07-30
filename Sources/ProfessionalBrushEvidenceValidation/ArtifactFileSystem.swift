import BrushFormat
import Foundation

enum ArtifactFileSystem {
    static func invalid(
        _ message: String
    ) -> ProfessionalBrushArtifactValidationError {
        .invalid(message)
    }

    static func regularFileData(_ url: URL, label: String) throws -> Data {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            throw invalid("\(label) must be a regular non-symlink file")
        }
        return try Data(contentsOf: url)
    }

    static func entryNames(_ directory: URL) throws -> Set<String> {
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw invalid(
                "\(directory.lastPathComponent) must be a non-symlink directory"
            )
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        )
        for entry in entries {
            guard try entry.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ).isSymbolicLink != true else {
                throw invalid("artifact tree contains a symbolic link")
            }
        }
        return Set(entries.map(\.lastPathComponent))
    }

    static func allRegularFiles(root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw invalid("artifact root cannot be enumerated")
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw invalid("artifact tree contains a symbolic link")
            }
            if values.isRegularFile == true {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func relativePath(_ url: URL, under root: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath()
            .standardizedFileURL.path + "/"
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            throw invalid("artifact path escapes root")
        }
        return String(path.dropFirst(rootPath.count))
    }

    static func jsonObject(_ data: Data, label: String) throws
        -> [String: Any]
    {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw invalid("\(label) JSON is malformed")
        }
        return object
    }

    static func requireExactKeys(
        _ object: [String: Any],
        _ expected: Set<String>,
        label: String
    ) throws {
        guard Set(object.keys) == expected else {
            throw invalid("\(label) keys are not exact")
        }
    }

    static func requireExactKeys(
        _ data: Data,
        _ expected: Set<String>,
        label: String
    ) throws {
        try requireExactKeys(
            jsonObject(data, label: label),
            expected,
            label: label
        )
    }

    static func sha256(_ data: Data) -> String {
        BrushContentHash.sha256Hex(of: data)
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(isLowerHex)
    }

    static func isCommit(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy(isLowerHex)
    }

    static func isLowerHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    static func nonemptyString(
        _ object: [String: Any],
        _ key: String
    ) -> String? {
        guard let value = object[key] as? String,
              !value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            return nil
        }
        return value
    }

    static func gpuClassification(_ name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("paravirtual") {
            return "paravirtual"
        }
        if lowered.contains("virtual") || lowered.contains("simulator") {
            return "virtual"
        }
        let physicalPatterns = [
            #"^apple [am][0-9]"#,
            #"^amd [a-z0-9]"#,
            #"^intel [a-z0-9]"#,
        ]
        return physicalPatterns.contains {
            lowered.range(of: $0, options: .regularExpression) != nil
        } ? "physical" : "unknown"
    }

    static func validateManifest(root: URL) throws {
        let manifestURL = root.appendingPathComponent("artifact-sha256.txt")
        let data = try regularFileData(
            manifestURL,
            label: "artifact digest manifest"
        )
        guard let text = String(data: data, encoding: .utf8),
              !text.isEmpty,
              text.hasSuffix("\n")
        else {
            throw invalid("artifact digest manifest is malformed")
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).dropLast().map(String.init)
        var manifest: [String: String] = [:]
        var paths: [String] = []
        for line in lines {
            guard line.count > 68 else {
                throw invalid("artifact digest manifest line is malformed")
            }
            let digest = String(line.prefix(64))
            let separator = line.dropFirst(64).prefix(4)
            let path = String(line.dropFirst(68))
            guard isSHA256(digest),
                  separator == "  ./",
                  !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(".."),
                  path != "artifact-sha256.txt",
                  manifest[path] == nil
            else {
                throw invalid("artifact digest manifest path is unsafe")
            }
            manifest[path] = digest
            paths.append(path)
        }
        guard paths == paths.sorted() else {
            throw invalid("artifact digest manifest paths are not sorted")
        }
        let files = try allRegularFiles(root: root).filter {
            $0.lastPathComponent != "artifact-sha256.txt"
        }
        let actual = try Set(files.map { try relativePath($0, under: root) })
        guard Set(manifest.keys) == actual else {
            throw invalid("artifact digest manifest file set is not exact")
        }
        for file in files {
            let path = try relativePath(file, under: root)
            guard manifest[path] == sha256(try Data(contentsOf: file)) else {
                throw invalid("artifact digest mismatch: \(path)")
            }
        }
    }

    static func exactTreeMatch(_ lhs: URL, _ rhs: URL) throws {
        let lhsFiles = try allRegularFiles(root: lhs)
        let rhsFiles = try allRegularFiles(root: rhs)
        let lhsPaths = try lhsFiles.map { try relativePath($0, under: lhs) }
        let rhsPaths = try rhsFiles.map { try relativePath($0, under: rhs) }
        guard lhsPaths == rhsPaths else {
            throw invalid("copied artifact tree file set is not exact")
        }
        for (left, right) in zip(lhsFiles, rhsFiles) {
            guard try regularFileData(left, label: "copied artifact")
                    == regularFileData(right, label: "source artifact")
            else {
                throw invalid("copied artifact bytes changed")
            }
        }
    }
}
