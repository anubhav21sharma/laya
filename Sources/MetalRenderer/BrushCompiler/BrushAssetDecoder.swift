import BrushFormat
import CoreGraphics
import Foundation
import ImageIO
import PatternEngine
import UniformTypeIdentifiers

public enum BrushAssetDecodeError: Error, Equatable, Sendable {
    case unsupportedResourceKind(id: String, kind: BrushResourceKind)
    case unsupportedMediaType(id: String, mediaType: String)
    case encodedByteCountMismatch(id: String, declared: Int, actual: Int)
    case contentHashMismatch(id: String)
    case invalidImage(id: String)
    case multipleImageFrames(id: String, count: Int)
    case imageTypeMismatch(
        id: String,
        declaredMediaType: String,
        actualTypeIdentifier: String
    )
    case missingImageProperties(id: String)
    case unsupportedColorModel(id: String, model: String)
    case unsupportedBitDepth(id: String, depth: Int)
    case floatingPointComponentsUnsupported(id: String)
    case unsupportedOrientation(id: String, orientation: Int)
    case invalidDimensions(id: String, width: Int, height: Int)
    case dimensionsExceedLimit(
        id: String,
        width: Int,
        height: Int,
        maximum: Int
    )
    case dimensionMismatch(
        id: String,
        declaredWidth: Int,
        declaredHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case decodedByteCountOverflow(id: String)
    case intermediateImageExceedsBounds(
        id: String,
        width: Int,
        height: Int,
        maximumDimension: Int
    )
    case intermediateImageAspectMismatch(
        id: String,
        width: Int,
        height: Int,
        sourceWidth: Int,
        sourceHeight: Int
    )
    case transientDecodedBytesExceedLimit(
        id: String,
        requested: Int,
        limit: Int
    )
    case mipByteCountOverflow(id: String)
    case imageDecodeFailed(id: String)
}

struct BrushAssetImageProperties: Equatable, Sendable {
    enum ColorModel: Equatable, Sendable {
        case gray
        case rgb
    }

    let width: Int
    let height: Int
    let colorModel: ColorModel
    let depth: Int
    let hasAlpha: Bool
    let sourceDecodedByteCount: Int
    let usesNativeLinearMonochromeCoverage: Bool

    var componentCount: Int {
        switch colorModel {
        case .gray:
            hasAlpha ? 2 : 1
        case .rgb:
            // CoreGraphics commonly expands RGB storage to four components
            // even when the encoded image has no alpha channel.
            4
        }
    }

    var bytesPerComponent: Int {
        (depth + 7) / 8
    }

    func decodedByteCount(
        resourceID: String,
        width: Int,
        height: Int
    ) throws -> Int {
        try BrushAssetSizing.checkedSourceDecodedByteCount(
            resourceID: resourceID,
            width: width,
            height: height,
            componentCount: componentCount,
            bytesPerComponent: bytesPerComponent
        )
    }

    static func validated(
        resourceID: String,
        properties: [CFString: Any]
    ) throws -> Self {
        let dimensions = try BrushAssetSizing.validatedSourceDimensions(
            resourceID: resourceID,
            width: (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
                .intValue,
            height: (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
                .intValue
        )
        guard let colorModelName =
            properties[kCGImagePropertyColorModel] as? String
        else {
            throw BrushAssetDecodeError.missingImageProperties(id: resourceID)
        }
        let grayColorModelName: String =
            kCGImagePropertyColorModelGray as String
        let rgbColorModelName: String =
            kCGImagePropertyColorModelRGB as String
        let colorModel: ColorModel
        switch colorModelName {
        case grayColorModelName:
            colorModel = .gray
        case rgbColorModelName:
            colorModel = .rgb
        default:
            throw BrushAssetDecodeError.unsupportedColorModel(
                id: resourceID,
                model: colorModelName
            )
        }

        guard let depth =
            (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue
        else {
            throw BrushAssetDecodeError.missingImageProperties(id: resourceID)
        }
        guard (1...16).contains(depth) else {
            throw BrushAssetDecodeError.unsupportedBitDepth(
                id: resourceID,
                depth: depth
            )
        }
        if (properties[kCGImagePropertyIsFloat] as? NSNumber)?.boolValue
            == true
        {
            throw BrushAssetDecodeError.floatingPointComponentsUnsupported(
                id: resourceID
            )
        }

        let orientation =
            (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            ?? 1
        guard orientation == 1 else {
            throw BrushAssetDecodeError.unsupportedOrientation(
                id: resourceID,
                orientation: orientation
            )
        }

        let hasAlpha =
            (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue
            ?? false
        let componentCount: Int
        switch colorModel {
        case .gray:
            componentCount = hasAlpha ? 2 : 1
        case .rgb:
            componentCount = 4
        }
        let sourceDecodedByteCount =
            try BrushAssetSizing.checkedSourceDecodedByteCount(
                resourceID: resourceID,
                width: dimensions.width,
                height: dimensions.height,
                componentCount: componentCount,
                bytesPerComponent: (depth + 7) / 8
            )
        return Self(
            width: dimensions.width,
            height: dimensions.height,
            colorModel: colorModel,
            depth: depth,
            hasAlpha: hasAlpha,
            sourceDecodedByteCount: sourceDecodedByteCount,
            usesNativeLinearMonochromeCoverage: colorModel == .gray
                && depth == 8
                && properties[kCGImagePropertyProfileName] == nil
        )
    }
}

struct BrushAssetWorkspaceEstimate: Equatable, Sendable {
    // A 4096-square, 16-bit RGBA intermediate peaks at 224 MiB while
    // converting to linear R8. The remaining 32 MiB covers row padding
    // without conflating transient decode workspace with resident cache cost.
    static let maximumPortableByteCount = 256 * 1_024 * 1_024

    let intermediateByteCount: Int
    let conversionScratchByteCount: Int
    let coverageStorageByteCount: Int
    let conversionPhasePeakByteCount: Int
    let mipGenerationPhasePeakByteCount: Int
    let peakByteCount: Int

    private let width: Int
    private let height: Int
    private let colorModel: BrushAssetImageProperties.ColorModel

    static func checked(
        resourceID: String,
        width: Int,
        height: Int,
        colorModel: BrushAssetImageProperties.ColorModel,
        intermediateByteCount: Int
    ) throws -> Self {
        let pixelCount = try BrushAssetSizing.checkedPixelCount(
            resourceID: resourceID,
            width: width,
            height: height
        )
        let conversionScratchByteCount =
            try BrushAssetSizing.checkedSourceDecodedByteCount(
                resourceID: resourceID,
                width: width,
                height: height,
                componentCount: colorModel == .gray ? 2 : 4,
                bytesPerComponent: 1
            )
        let coverageStorageByteCount =
            try BrushAssetSizing.checkedSourceDecodedByteCount(
                resourceID: resourceID,
                width: width,
                height: height,
                componentCount: 2,
                bytesPerComponent: 1
            )
        // Coverage exists as both a mutable UInt8 array and the returned Data
        // while the decoded image and conversion context are still live.
        let conversionPhasePeakByteCount =
            try BrushAssetSizing.checkedDecodedByteSum(
                resourceID: resourceID,
                byteCounts: [
                    intermediateByteCount,
                    conversionScratchByteCount,
                    coverageStorageByteCount,
                ]
            )

        let mipLevelByteCounts =
            try BrushAssetSizing.checkedMipLevelByteCounts(
                resourceID: resourceID,
                width: width,
                height: height
            )
        let residentMipByteCount = try BrushAssetSizing.checkedMipByteCount(
            resourceID: resourceID,
            levelByteCounts: mipLevelByteCounts
        )
        let nextMipByteCount = mipLevelByteCounts.dropFirst().first ?? 0
        // Mip generation retains completed Data levels, the current array,
        // and both the next array and its Data copy at the append boundary.
        let mipGenerationPhasePeakByteCount =
            try BrushAssetSizing.checkedDecodedByteSum(
                resourceID: resourceID,
                byteCounts: [
                    residentMipByteCount,
                    pixelCount,
                    nextMipByteCount,
                    nextMipByteCount,
                ]
            )
        return Self(
            intermediateByteCount: intermediateByteCount,
            conversionScratchByteCount: conversionScratchByteCount,
            coverageStorageByteCount: coverageStorageByteCount,
            conversionPhasePeakByteCount: conversionPhasePeakByteCount,
            mipGenerationPhasePeakByteCount: mipGenerationPhasePeakByteCount,
            peakByteCount: max(
                conversionPhasePeakByteCount,
                mipGenerationPhasePeakByteCount
            ),
            width: width,
            height: height,
            colorModel: colorModel
        )
    }

    func replacingIntermediateByteCount(
        resourceID: String,
        intermediateByteCount: Int
    ) throws -> Self {
        try Self.checked(
            resourceID: resourceID,
            width: width,
            height: height,
            colorModel: colorModel,
            intermediateByteCount: intermediateByteCount
        )
    }

    func validate(resourceID: String, limit: Int) throws {
        try BrushAssetSizing.validateTransientDecodedByteCount(
            resourceID: resourceID,
            requested: peakByteCount,
            limit: limit
        )
    }
}

enum BrushAssetSizing {
    static func validatedSourceDimensions(
        resourceID: String,
        width: Int?,
        height: Int?
    ) throws -> (width: Int, height: Int) {
        guard let width, let height else {
            throw BrushAssetDecodeError.missingImageProperties(id: resourceID)
        }
        guard width > 0, height > 0 else {
            throw BrushAssetDecodeError.invalidDimensions(
                id: resourceID,
                width: width,
                height: height
            )
        }
        return (width, height)
    }

    static func checkedPixelCount(
        resourceID: String,
        width: Int,
        height: Int
    ) throws -> Int {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, count >= 0 else {
            throw BrushAssetDecodeError.decodedByteCountOverflow(id: resourceID)
        }
        return count
    }

    static func checkedSourceDecodedByteCount(
        resourceID: String,
        width: Int,
        height: Int,
        componentCount: Int,
        bytesPerComponent: Int
    ) throws -> Int {
        var count = try checkedPixelCount(
            resourceID: resourceID,
            width: width,
            height: height
        )
        for factor in [componentCount, bytesPerComponent] {
            let (next, overflow) = count.multipliedReportingOverflow(by: factor)
            guard !overflow, factor > 0, next >= 0 else {
                throw BrushAssetDecodeError.decodedByteCountOverflow(
                    id: resourceID
                )
            }
            count = next
        }
        return count
    }

    static func checkedDecodedByteSum(
        resourceID: String,
        byteCounts: [Int]
    ) throws -> Int {
        var total = 0
        for count in byteCounts {
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow, count >= 0, next >= 0 else {
                throw BrushAssetDecodeError.decodedByteCountOverflow(
                    id: resourceID
                )
            }
            total = next
        }
        return total
    }

    static func checkedMipLevelByteCounts(
        resourceID: String,
        width: Int,
        height: Int
    ) throws -> [Int] {
        var currentWidth = width
        var currentHeight = height
        var counts = [
            try checkedPixelCount(
                resourceID: resourceID,
                width: currentWidth,
                height: currentHeight
            ),
        ]
        while currentWidth > 1 || currentHeight > 1 {
            currentWidth = max(1, currentWidth / 2)
            currentHeight = max(1, currentHeight / 2)
            counts.append(
                try checkedPixelCount(
                    resourceID: resourceID,
                    width: currentWidth,
                    height: currentHeight
                )
            )
        }
        return counts
    }

    static func validateIntermediateDimensions(
        resourceID: String,
        width: Int,
        height: Int,
        maximumDimension: Int
    ) throws {
        guard width > 0, height > 0 else {
            throw BrushAssetDecodeError.invalidDimensions(
                id: resourceID,
                width: width,
                height: height
            )
        }
        guard width <= maximumDimension, height <= maximumDimension else {
            throw BrushAssetDecodeError.intermediateImageExceedsBounds(
                id: resourceID,
                width: width,
                height: height,
                maximumDimension: maximumDimension
            )
        }
    }

    static func validateIntermediateAspect(
        resourceID: String,
        width: Int,
        height: Int,
        sourceWidth: Int,
        sourceHeight: Int
    ) throws {
        let crossDifference = abs(width * sourceHeight - height * sourceWidth)
        let roundingTolerance = (sourceWidth + sourceHeight + 1) / 2
        guard crossDifference <= roundingTolerance else {
            throw BrushAssetDecodeError.intermediateImageAspectMismatch(
                id: resourceID,
                width: width,
                height: height,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            )
        }
    }

    static func validateTransientDecodedByteCount(
        resourceID: String,
        requested: Int,
        limit: Int
    ) throws {
        guard requested <= limit else {
            throw BrushAssetDecodeError.transientDecodedBytesExceedLimit(
                id: resourceID,
                requested: requested,
                limit: limit
            )
        }
    }

    static func checkedMipByteCount(
        resourceID: String,
        levelByteCounts: [Int]
    ) throws -> Int {
        var total = 0
        for count in levelByteCounts {
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow, count >= 0 else {
                throw BrushAssetDecodeError.mipByteCountOverflow(id: resourceID)
            }
            total = next
        }
        return total
    }
}

public enum BrushAssetDecoder {
    private static let maximumSourceDimension = 8_192

    public static func decode(
        resource: BrushPackageResource,
        data: Data,
        profile: BrushDeviceProfile
    ) throws -> DecodedBrushTexture {
        switch resource.kind {
        case .shape, .grain:
            break
        case .preview:
            throw BrushAssetDecodeError.unsupportedResourceKind(
                id: resource.id,
                kind: resource.kind
            )
        }

        let expectedType: UTType
        switch resource.mediaType {
        case "image/png":
            expectedType = .png
        case "image/tiff":
            expectedType = .tiff
        default:
            throw BrushAssetDecodeError.unsupportedMediaType(
                id: resource.id,
                mediaType: resource.mediaType
            )
        }

        guard resource.encodedByteCount == data.count else {
            throw BrushAssetDecodeError.encodedByteCountMismatch(
                id: resource.id,
                declared: resource.encodedByteCount,
                actual: data.count
            )
        }
        guard BrushContentHash.sha256Hex(of: data) == resource.sha256 else {
            throw BrushAssetDecodeError.contentHashMismatch(id: resource.id)
        }

        let sourceOptions = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions
        ) else {
            throw BrushAssetDecodeError.invalidImage(id: resource.id)
        }
        let imageCount = CGImageSourceGetCount(imageSource)
        guard imageCount == 1 else {
            if imageCount > 1 {
                throw BrushAssetDecodeError.multipleImageFrames(
                    id: resource.id,
                    count: imageCount
                )
            }
            throw BrushAssetDecodeError.invalidImage(id: resource.id)
        }

        guard let actualTypeIdentifier = CGImageSourceGetType(imageSource)
            as String?
        else {
            throw BrushAssetDecodeError.invalidImage(id: resource.id)
        }
        guard actualTypeIdentifier == expectedType.identifier else {
            throw BrushAssetDecodeError.imageTypeMismatch(
                id: resource.id,
                declaredMediaType: resource.mediaType,
                actualTypeIdentifier: actualTypeIdentifier
            )
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            imageSource,
            0,
            sourceOptions
        ) as? [CFString: Any]
        else {
            throw BrushAssetDecodeError.missingImageProperties(id: resource.id)
        }
        let imageProperties = try BrushAssetImageProperties.validated(
            resourceID: resource.id,
            properties: properties
        )
        let dimensions = (
            width: imageProperties.width,
            height: imageProperties.height
        )
        guard dimensions.width <= maximumSourceDimension,
              dimensions.height <= maximumSourceDimension
        else {
            throw BrushAssetDecodeError.dimensionsExceedLimit(
                id: resource.id,
                width: dimensions.width,
                height: dimensions.height,
                maximum: maximumSourceDimension
            )
        }
        _ = try BrushAssetSizing.checkedPixelCount(
            resourceID: resource.id,
            width: dimensions.width,
            height: dimensions.height
        )
        guard dimensions.width == resource.pixelWidth,
              dimensions.height == resource.pixelHeight
        else {
            throw BrushAssetDecodeError.dimensionMismatch(
                id: resource.id,
                declaredWidth: resource.pixelWidth,
                declaredHeight: resource.pixelHeight,
                actualWidth: dimensions.width,
                actualHeight: dimensions.height
            )
        }

        let working = workingDimensions(
            sourceWidth: dimensions.width,
            sourceHeight: dimensions.height,
            ceiling: profile.maximumWorkingTextureDimension
        )
        let resampling = working.width != dimensions.width
            || working.height != dimensions.height
        let estimatedIntermediateByteCount: Int
        if resampling {
            estimatedIntermediateByteCount =
                try imageProperties.decodedByteCount(
                    resourceID: resource.id,
                    width: working.width,
                    height: working.height
                )
        } else {
            estimatedIntermediateByteCount =
                imageProperties.sourceDecodedByteCount
        }
        let workspaceEstimate = try BrushAssetWorkspaceEstimate.checked(
            resourceID: resource.id,
            width: working.width,
            height: working.height,
            colorModel: imageProperties.colorModel,
            intermediateByteCount: estimatedIntermediateByteCount
        )
        try workspaceEstimate.validate(
            resourceID: resource.id,
            limit: BrushAssetWorkspaceEstimate.maximumPortableByteCount
        )
        let baseLevel = try decodeLinearCoverage(
            imageSource: imageSource,
            resourceID: resource.id,
            imageProperties: imageProperties,
            width: working.width,
            height: working.height,
            resampling: resampling,
            sourceOptions: sourceOptions,
            workspaceEstimate: workspaceEstimate
        )
        let mipLevels = try makeMipLevels(
            resourceID: resource.id,
            baseLevel: baseLevel,
            width: working.width,
            height: working.height
        )
        let residentByteCount = try BrushAssetSizing.checkedMipByteCount(
            resourceID: resource.id,
            levelByteCounts: mipLevels.map(\.count)
        )
        let tipSupport: BrushTipAssetSupport?
        switch resource.kind {
        case .shape:
            do {
                tipSupport = try BrushTipAssetSupportCompiler.compile(
                    baseLevel: baseLevel,
                    width: working.width,
                    height: working.height
                )
            } catch {
                throw BrushAssetDecodeError.invalidImage(id: resource.id)
            }
        case .grain, .preview:
            tipSupport = nil
        }
        return DecodedBrushTexture(
            resourceID: resource.id,
            kind: resource.kind,
            sourceWidth: dimensions.width,
            sourceHeight: dimensions.height,
            workingWidth: working.width,
            workingHeight: working.height,
            mipLevels: mipLevels,
            residentByteCount: residentByteCount,
            wasResampled: resampling,
            tipSupport: tipSupport
        )
    }

    private static func workingDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        ceiling: Int
    ) -> (width: Int, height: Int) {
        let longest = max(sourceWidth, sourceHeight)
        guard longest > ceiling else {
            return (sourceWidth, sourceHeight)
        }
        let scale = Double(ceiling) / Double(longest)
        return (
            max(1, Int((Double(sourceWidth) * scale).rounded())),
            max(1, Int((Double(sourceHeight) * scale).rounded()))
        )
    }

    private static func decodeLinearCoverage(
        imageSource: CGImageSource,
        resourceID: String,
        imageProperties: BrushAssetImageProperties,
        width: Int,
        height: Int,
        resampling: Bool,
        sourceOptions: CFDictionary,
        workspaceEstimate: BrushAssetWorkspaceEstimate
    ) throws -> Data {
        let pixelCount = try BrushAssetSizing.checkedPixelCount(
            resourceID: resourceID,
            width: width,
            height: height
        )
        let image: CGImage?
        let maximumDecodedDimension: Int
        if resampling {
            maximumDecodedDimension = max(width, height)
            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: maximumDecodedDimension,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceShouldAllowFloat: false,
            ] as CFDictionary
            image = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                thumbnailOptions
            )
        } else {
            maximumDecodedDimension = max(
                imageProperties.width,
                imageProperties.height
            )
            image = CGImageSourceCreateImageAtIndex(
                imageSource,
                0,
                sourceOptions
            )
        }
        guard let image else {
            throw BrushAssetDecodeError.imageDecodeFailed(id: resourceID)
        }
        try BrushAssetSizing.validateIntermediateDimensions(
            resourceID: resourceID,
            width: image.width,
            height: image.height,
            maximumDimension: maximumDecodedDimension
        )
        if resampling {
            try BrushAssetSizing.validateIntermediateAspect(
                resourceID: resourceID,
                width: image.width,
                height: image.height,
                sourceWidth: imageProperties.width,
                sourceHeight: imageProperties.height
            )
        } else {
            guard image.width == imageProperties.width,
                  image.height == imageProperties.height
            else {
                throw BrushAssetDecodeError.imageDecodeFailed(id: resourceID)
            }
        }
        let actualIntermediateByteCount =
            try BrushAssetSizing.checkedSourceDecodedByteCount(
                resourceID: resourceID,
                width: image.bytesPerRow,
                height: image.height,
                componentCount: 1,
                bytesPerComponent: 1
            )
        let actualWorkspaceEstimate =
            try workspaceEstimate.replacingIntermediateByteCount(
                resourceID: resourceID,
                intermediateByteCount: actualIntermediateByteCount
            )
        try actualWorkspaceEstimate.validate(
            resourceID: resourceID,
            limit: BrushAssetWorkspaceEstimate.maximumPortableByteCount
        )

        if imageProperties.colorModel == .gray {
            let colorSpace: CGColorSpace
            if imageProperties.usesNativeLinearMonochromeCoverage {
                colorSpace = CGColorSpaceCreateDeviceGray()
            } else {
                colorSpace = CGColorSpace(name: CGColorSpace.linearGray)
                    ?? CGColorSpaceCreateDeviceGray()
            }
            return try decodeMonochromeCoverage(
                image: image,
                resourceID: resourceID,
                pixelCount: pixelCount,
                width: width,
                height: height,
                resampling: resampling,
                colorSpace: colorSpace
            )
        }
        return try decodeLinearRGBCoverage(
            image: image,
            resourceID: resourceID,
            pixelCount: pixelCount,
            width: width,
            height: height,
            resampling: resampling
        )
    }

    private static func decodeMonochromeCoverage(
        image: CGImage,
        resourceID: String,
        pixelCount: Int,
        width: Int,
        height: Int,
        resampling: Bool,
        colorSpace: CGColorSpace
    ) throws -> Data {
        let (grayAlphaByteCount, overflow) = pixelCount
            .multipliedReportingOverflow(by: 2)
        guard !overflow else {
            throw BrushAssetDecodeError.decodedByteCountOverflow(id: resourceID)
        }
        var grayAlpha = [UInt8](repeating: 0, count: grayAlphaByteCount)
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context = CGContext(
            data: &grayAlpha,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 2,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw BrushAssetDecodeError.imageDecodeFailed(id: resourceID)
        }
        draw(
            image,
            into: context,
            width: width,
            height: height,
            resampling: resampling
        )
        var coverage = [UInt8](repeating: 0, count: pixelCount)
        for pixel in 0..<pixelCount {
            coverage[pixel] = grayAlpha[pixel * 2]
        }
        return Data(coverage)
    }

    private static func decodeLinearRGBCoverage(
        image: CGImage,
        resourceID: String,
        pixelCount: Int,
        width: Int,
        height: Int,
        resampling: Bool
    ) throws -> Data {
        let (rgbaByteCount, overflow) = pixelCount
            .multipliedReportingOverflow(by: 4)
        guard !overflow else {
            throw BrushAssetDecodeError.decodedByteCountOverflow(id: resourceID)
        }
        var rgba = [UInt8](repeating: 0, count: rgbaByteCount)
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw BrushAssetDecodeError.imageDecodeFailed(id: resourceID)
        }
        draw(
            image,
            into: context,
            width: width,
            height: height,
            resampling: resampling
        )

        var coverage = [UInt8](repeating: 0, count: pixelCount)
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            let red = Int(rgba[offset])
            let green = Int(rgba[offset + 1])
            let blue = Int(rgba[offset + 2])
            // Components are already premultiplied by alpha and converted to
            // linear sRGB. Integer Rec. 709 weights sum to 10_000.
            coverage[pixel] = UInt8(
                (2_126 * red + 7_152 * green + 722 * blue + 5_000) / 10_000
            )
        }
        return Data(coverage)
    }

    private static func draw(
        _ image: CGImage,
        into context: CGContext,
        width: Int,
        height: Int,
        resampling: Bool
    ) {
        context.setBlendMode(.copy)
        context.interpolationQuality = resampling ? .high : .none
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    private static func makeMipLevels(
        resourceID: String,
        baseLevel: Data,
        width: Int,
        height: Int
    ) throws -> [Data] {
        var levels = [baseLevel]
        var current = [UInt8](baseLevel)
        var currentWidth = width
        var currentHeight = height

        while currentWidth > 1 || currentHeight > 1 {
            let nextWidth = max(1, currentWidth / 2)
            let nextHeight = max(1, currentHeight / 2)
            let nextCount = try BrushAssetSizing.checkedPixelCount(
                resourceID: resourceID,
                width: nextWidth,
                height: nextHeight
            )
            var next = [UInt8](repeating: 0, count: nextCount)
            for destinationY in 0..<nextHeight {
                for destinationX in 0..<nextWidth {
                    var sum = 0
                    var sampleCount = 0
                    let sourceYStart =
                        destinationY * currentHeight / nextHeight
                    let sourceYEnd =
                        (destinationY + 1) * currentHeight / nextHeight
                    let sourceXStart =
                        destinationX * currentWidth / nextWidth
                    let sourceXEnd =
                        (destinationX + 1) * currentWidth / nextWidth
                    for y in sourceYStart..<sourceYEnd {
                        for x in sourceXStart..<sourceXEnd {
                            sum += Int(current[y * currentWidth + x])
                            sampleCount += 1
                        }
                    }
                    next[destinationY * nextWidth + destinationX] = UInt8(
                        (sum + sampleCount / 2) / sampleCount
                    )
                }
            }
            levels.append(Data(next))
            current = next
            currentWidth = nextWidth
            currentHeight = nextHeight
        }
        return levels
    }
}

enum BrushTipAssetSupportCompilationError: Error, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case byteCountOverflow
    case byteCountMismatch(expected: Int, actual: Int)
    case emptySupport
}

enum BrushTipAssetSupportCompiler {
    static func compile(
        baseLevel: Data,
        width: Int,
        height: Int
    ) throws -> BrushTipAssetSupport {
        guard width > 0, height > 0 else {
            throw BrushTipAssetSupportCompilationError.invalidDimensions(
                width: width,
                height: height
            )
        }
        let (expectedCount, overflow) = width.multipliedReportingOverflow(
            by: height
        )
        guard !overflow else {
            throw BrushTipAssetSupportCompilationError.byteCountOverflow
        }
        guard baseLevel.count == expectedCount else {
            throw BrushTipAssetSupportCompilationError.byteCountMismatch(
                expected: expectedCount,
                actual: baseLevel.count
            )
        }

        var boundaryPoints: [SIMD2<Float>] = []
        let rowBoundaryCapacity = height.multipliedReportingOverflow(by: 4)
        let texelBoundaryCapacity = expectedCount.multipliedReportingOverflow(by: 4)
        let safeRowCapacity = rowBoundaryCapacity.overflow
            ? Int.max
            : rowBoundaryCapacity.partialValue
        let safeTexelCapacity = texelBoundaryCapacity.overflow
            ? Int.max
            : texelBoundaryCapacity.partialValue
        boundaryPoints.reserveCapacity(min(safeRowCapacity, safeTexelCapacity))
        var minimumX = width
        var maximumX = -1
        var minimumY = height
        var maximumY = -1

        baseLevel.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                var rowMinimum = width
                var rowMaximum = -1
                // A one-code R8 value is below the deposition shader's
                // anti-aliased tip threshold and can be introduced by lossless
                // normalization at otherwise empty texels. Treating it as
                // visible would expand cached cursor/support bounds to the
                // whole texture even though it cannot contribute a pixel.
                for x in 0..<width where bytes[y * width + x] > 1 {
                    rowMinimum = min(rowMinimum, x)
                    rowMaximum = max(rowMaximum, x)
                }
                guard rowMaximum >= rowMinimum else { continue }
                minimumX = min(minimumX, rowMinimum)
                maximumX = max(maximumX, rowMaximum)
                minimumY = min(minimumY, y)
                maximumY = max(maximumY, y)

                let left = normalizedEdge(rowMinimum, dimension: width)
                let right = normalizedEdge(rowMaximum + 1, dimension: width)
                let top = normalizedEdge(y, dimension: height)
                let bottom = normalizedEdge(y + 1, dimension: height)
                boundaryPoints.append(SIMD2(left, top))
                boundaryPoints.append(SIMD2(right, top))
                boundaryPoints.append(SIMD2(right, bottom))
                boundaryPoints.append(SIMD2(left, bottom))
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else {
            throw BrushTipAssetSupportCompilationError.emptySupport
        }

        let bounds = try BrushTipNormalizedBounds(
            minX: normalizedEdge(minimumX, dimension: width),
            maxX: normalizedEdge(maximumX + 1, dimension: width),
            minY: normalizedEdge(minimumY, dimension: height),
            maxY: normalizedEdge(maximumY + 1, dimension: height)
        )
        return try BrushTipAssetSupport(
            bounds: bounds,
            contour: boundedConservativeConvexHull(boundaryPoints),
            padding: .zero
        )
    }

    private static func normalizedEdge(
        _ coordinate: Int,
        dimension: Int
    ) -> Float {
        Float(coordinate) / Float(dimension) * 2 - 1
    }

    private static func boundedConservativeConvexHull(
        _ points: [SIMD2<Float>]
    ) -> [SIMD2<Float>] {
        let sorted = Array(Set(points)).sorted {
            $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
        }
        guard sorted.count > 2 else { return sorted }

        var lower: [SIMD2<Float>] = []
        for point in sorted {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], point)
                    <= 0
            {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [SIMD2<Float>] = []
        for point in sorted.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], point)
                    <= 0
            {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        let hull = lower + upper
        let maximumContourPointCount = 128
        guard hull.count > maximumContourPointCount else { return hull }
        let minimumX = points.map(\.x).min()!
        let maximumX = points.map(\.x).max()!
        let minimumY = points.map(\.y).min()!
        let maximumY = points.map(\.y).max()!
        return [
            SIMD2(minimumX, minimumY),
            SIMD2(maximumX, minimumY),
            SIMD2(maximumX, maximumY),
            SIMD2(minimumX, maximumY),
        ]
    }

    private static func cross(
        _ origin: SIMD2<Float>,
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>
    ) -> Float {
        let first = a - origin
        let second = b - origin
        return first.x * second.y - first.y * second.x
    }
}
