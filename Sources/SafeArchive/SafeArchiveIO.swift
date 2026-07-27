import Foundation

public enum SafeArchiveIO {
    public static func save(
        entries: [String: Data],
        to destination: URL,
        limits: SafeArchiveLimits
    ) throws {
        try save(
            entries: entries,
            to: destination,
            limits: limits,
            beforeReplacement: { _ in }
        )
    }

    package static func save(
        entries: [String: Data],
        to destination: URL,
        limits: SafeArchiveLimits,
        beforeReplacement: (URL) throws -> Void
    ) throws {
        let archive = try SafeArchiveCodec.encode(entries: entries, limits: limits)
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try archive.write(to: temporary, options: [.withoutOverwriting])
            _ = try SafeArchiveCodec.open(
                Data(contentsOf: temporary, options: [.mappedIfSafe]),
                limits: limits
            )
            try beforeReplacement(temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination, withItemAt: temporary, backupItemName: nil, options: []
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch let error as SafeArchiveError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch let error as SafeArchiveSaveHookError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw SafeArchiveError.saveFailed
        }
    }
}

package enum SafeArchiveSaveHookError: Error, Equatable {
    case beforeReplacement
}
