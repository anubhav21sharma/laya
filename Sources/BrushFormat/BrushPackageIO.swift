import Foundation

public enum BrushPackageIO {
    public static func save(
        _ package: BrushPackage,
        to destination: URL
    ) throws {
        try save(
            package,
            to: destination,
            replacingExisting: true,
            beforeReplacement: { _ in }
        )
    }

    public static func save(
        _ package: BrushPackage,
        to destination: URL,
        replacingExisting: Bool
    ) throws {
        try save(
            package,
            to: destination,
            replacingExisting: replacingExisting,
            beforeReplacement: { _ in }
        )
    }

    package static func save(
        _ package: BrushPackage,
        to destination: URL,
        replacingExisting: Bool = true,
        beforeReplacement: (URL) throws -> Void
    ) throws {
        let encoded = try BrushPackageCodec.encode(package)
        let expectedHash = try package.contentHash
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try encoded.write(to: temporary, options: [.withoutOverwriting])
            let reopenedBytes = try Data(contentsOf: temporary, options: [.mappedIfSafe])
            let reopened = try BrushPackageCodec.decode(reopenedBytes)
            guard reopened == package,
                  try reopened.contentHash == expectedHash
            else {
                throw BrushPackageError.contentIdentityMismatch
            }
            try beforeReplacement(temporary)
            if fileManager.fileExists(atPath: destination.path) {
                guard replacingExisting else {
                    throw BrushPackageError.ioFailure
                }
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch let error as BrushPackageError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw BrushPackageError.ioFailure
        }
    }

    public static func load(from source: URL) throws -> BrushPackage {
        do {
            return try BrushPackageCodec.decode(
                Data(contentsOf: source, options: [.mappedIfSafe])
            )
        } catch let error as BrushPackageError {
            throw error
        } catch {
            throw BrushPackageError.ioFailure
        }
    }
}
