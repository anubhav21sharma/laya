import Foundation
import Testing
@testable import BrushFormat

@Test func packageIOSavesLoadsAndAtomicallyReplaces() throws {
    let directory = try BrushFormatTestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("brush.layabrush")
    let first = try BrushFormatTestSupport.package()

    try BrushPackageIO.save(first, to: destination)
    #expect(try BrushPackageIO.load(from: destination) == first)

    var changedBytes = try BrushFormatTestSupport.fixturePNG()
    changedBytes.append(7)
    let second = try BrushFormatTestSupport.package(resourceBytes: changedBytes)
    try BrushPackageIO.save(second, to: destination)

    #expect(try BrushPackageIO.load(from: destination) == second)
    #expect(try second.contentHash != first.contentHash)
    #expect(try temporaryFiles(in: directory).isEmpty)
}

@Test func packageIOReopensFullyBeforeReplacement() throws {
    let directory = try BrushFormatTestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("brush.layabrush")
    let package = try BrushFormatTestSupport.package()
    var observed: BrushPackage?

    try BrushPackageIO.save(
        package,
        to: destination,
        beforeReplacement: { temporary in
            observed = try BrushPackageCodec.decode(
                Data(contentsOf: temporary, options: [.mappedIfSafe])
            )
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    )

    #expect(observed == package)
    #expect(try BrushPackageIO.load(from: destination) == package)
}

@Test func interruptedReplacementPreservesOldBytesAndCleansTemporaryFile() throws {
    let directory = try BrushFormatTestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("brush.layabrush")
    let original = Data("existing destination".utf8)
    try original.write(to: destination)

    #expect(throws: BrushPackageError.ioFailure) {
        try BrushPackageIO.save(
            BrushFormatTestSupport.package(),
            to: destination,
            beforeReplacement: { _ in throw InjectedFailure.stop }
        )
    }

    #expect(try Data(contentsOf: destination) == original)
    #expect(try temporaryFiles(in: directory).isEmpty)
}

@Test func concurrentIndependentPackageSavesRemainValid() async throws {
    let directory = try BrushFormatTestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try BrushFormatTestSupport.package()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<8 {
            group.addTask {
                let destination = directory.appendingPathComponent("\(index).layabrush")
                try BrushPackageIO.save(package, to: destination)
                guard try BrushPackageIO.load(from: destination) == package else {
                    throw InjectedFailure.stop
                }
            }
        }
        try await group.waitForAll()
    }

    #expect(try temporaryFiles(in: directory).isEmpty)
}

private enum InjectedFailure: Error {
    case stop
}

private func temporaryFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasSuffix(".tmp") }
}
