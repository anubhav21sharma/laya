import Metal

enum BrushResourceCacheError: Error, Equatable, Sendable {
    case missingCandidate(String)
    case candidateByteCountMismatch(
        key: String,
        expected: Int,
        actual: Int
    )
}

enum BrushResourceCacheKey {
    static let schemaVersion = 1
    static let mipPolicyVersion = "floor-area-v1"

    static func make(
        contentHash: String,
        sourceValidationHash: String,
        width: Int,
        height: Int
    ) -> String {
        "brush-r8-v\(schemaVersion):\(contentHash):source=\(sourceValidationHash):\(width)x\(height):r8Unorm:\(mipPolicyVersion)"
    }
}

@MainActor
struct BrushResourceCache {
    struct Entry {
        let texture: any MTLTexture
        let byteCount: Int
    }

    struct Candidate {
        let texture: any MTLTexture
        let byteCount: Int
    }

    private(set) var entries: [String: Entry]
    private(set) var residency: BrushResourceResidency

    init(byteBudget: Int) {
        entries = [:]
        residency = BrushResourceResidency(byteBudget: byteBudget)
    }

    var keys: [String] {
        residency.keys
    }

    var pinnedKeys: [String] {
        residency.pinnedKeys
    }

    var residentByteCount: Int {
        residency.residentByteCount
    }

    func entry(for key: String) -> Entry? {
        entries[key]
    }

    /// Applies the complete unpin/admit/pin/evict/cache transaction to a copy
    /// and installs it only after every resource has been admitted.
    mutating func activate(
        activeKeys: Set<String>,
        candidates: [String: Candidate]
    ) throws -> [String] {
        var staged = self
        for key in staged.residency.pinnedKeys {
            staged.residency.unpin(key)
        }

        // Protect every cached member of the next active set before admitting
        // any misses. Otherwise a lexically earlier miss could evict a later
        // cache hit that has no candidate because it needed no upload.
        for key in activeKeys.sorted() where staged.entries[key] != nil {
            staged.residency.pin(key)
        }

        var evictedKeys: [String] = []
        for key in activeKeys.sorted() {
            let entry: Entry
            if let cached = staged.entries[key] {
                if let candidate = candidates[key],
                   candidate.byteCount != cached.byteCount
                {
                    throw BrushResourceCacheError.candidateByteCountMismatch(
                        key: key,
                        expected: cached.byteCount,
                        actual: candidate.byteCount
                    )
                }
                entry = cached
            } else {
                guard let candidate = candidates[key] else {
                    throw BrushResourceCacheError.missingCandidate(key)
                }
                entry = Entry(
                    texture: candidate.texture,
                    byteCount: candidate.byteCount
                )
            }

            let evicted = try staged.residency.access(
                key: key,
                byteCount: entry.byteCount,
                pinned: true
            )
            for victim in evicted {
                staged.entries.removeValue(forKey: victim)
            }
            evictedKeys.append(contentsOf: evicted)
            staged.entries[key] = entry
        }
        self = staged
        return evictedKeys
    }

    mutating func handleMemoryPressure(
        targetResidentBytes: Int
    ) -> BrushResourcePressureResult {
        let effectiveTarget = max(0, targetResidentBytes)
        let pinnedBytes = residency.pinnedByteCount
        guard effectiveTarget >= pinnedBytes else {
            return .activeBrushExceedsTarget(
                requiredBytes: pinnedBytes,
                targetBytes: targetResidentBytes
            )
        }

        var staged = self
        guard let result = try? staged.residency.applyMemoryPressure(
            targetResidentBytes: effectiveTarget
        ) else {
            return .activeBrushExceedsTarget(
                requiredBytes: pinnedBytes,
                targetBytes: targetResidentBytes
            )
        }
        if case let .satisfied(evictedKeys) = result {
            for key in evictedKeys {
                staged.entries.removeValue(forKey: key)
            }
            self = staged
        }
        return result
    }
}
