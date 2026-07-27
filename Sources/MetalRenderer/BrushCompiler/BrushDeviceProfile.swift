import Foundation

public enum BrushDeviceProfileError: Error, Equatable, Sendable {
    case invalidRecommendedWorkingSetBytes
    case invalidMaximumWorkingTextureDimension(Int)
    case invalidBrushCacheBudgetBytes(Int)
    case invalidTargetFramesPerSecond(Int)
}

public struct BrushDeviceProfile: Equatable, Sendable {
    public static let maximumPortableTextureDimension = 4_096

    public let registryID: UInt64
    public let recommendedWorkingSetBytes: UInt64
    public let maximumWorkingTextureDimension: Int
    public let brushCacheBudgetBytes: Int
    public let targetFramesPerSecond: Int

    public init(
        registryID: UInt64,
        recommendedWorkingSetBytes: UInt64,
        maximumWorkingTextureDimension: Int,
        brushCacheBudgetBytes: Int? = nil,
        targetFramesPerSecond: Int
    ) throws {
        guard recommendedWorkingSetBytes > 0 else {
            throw BrushDeviceProfileError.invalidRecommendedWorkingSetBytes
        }
        guard (1...Self.maximumPortableTextureDimension)
            .contains(maximumWorkingTextureDimension)
        else {
            throw BrushDeviceProfileError.invalidMaximumWorkingTextureDimension(
                maximumWorkingTextureDimension
            )
        }
        guard targetFramesPerSecond > 0 else {
            throw BrushDeviceProfileError.invalidTargetFramesPerSecond(
                targetFramesPerSecond
            )
        }

        let cacheBudget: Int
        if let brushCacheBudgetBytes {
            guard brushCacheBudgetBytes > 0 else {
                throw BrushDeviceProfileError.invalidBrushCacheBudgetBytes(
                    brushCacheBudgetBytes
                )
            }
            cacheBudget = brushCacheBudgetBytes
        } else {
            let floor = 64 * 1_024 * 1_024
            let ceiling = 256 * 1_024 * 1_024
            let tenPercent = recommendedWorkingSetBytes / 10
            let bounded = min(UInt64(ceiling), max(UInt64(floor), tenPercent))
            cacheBudget = Int(bounded)
        }

        self.registryID = registryID
        self.recommendedWorkingSetBytes = recommendedWorkingSetBytes
        self.maximumWorkingTextureDimension = maximumWorkingTextureDimension
        self.brushCacheBudgetBytes = cacheBudget
        self.targetFramesPerSecond = targetFramesPerSecond
    }
}
