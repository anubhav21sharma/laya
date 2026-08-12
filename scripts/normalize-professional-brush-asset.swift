#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NormalizationMode: String {
    case tip
    case grain
}

enum NormalizationError: Error, CustomStringConvertible {
    case usage
    case invalidSize
    case invalidImage
    case outputCreation

    var description: String {
        switch self {
        case .usage:
            "usage: normalize-professional-brush-asset.swift <tip|grain> <size> <input> <output.png> <output.r8>"
        case .invalidSize:
            "size must be a positive integer"
        case .invalidImage:
            "input is not a decodable single-frame image"
        case .outputCreation:
            "could not create normalized output"
        }
    }
}

func percentile(_ values: [UInt8], fraction: Double) -> UInt8 {
    let sorted = values.sorted()
    let index = min(
        sorted.count - 1,
        max(0, Int((Double(sorted.count - 1) * fraction).rounded()))
    )
    return sorted[index]
}

func decodeSquareLuminance(
    url: URL,
    size: Int,
    cropScale: Double
) throws -> [UInt8] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, [
              kCGImageSourceShouldCacheImmediately: true,
              kCGImageSourceShouldAllowFloat: false,
          ] as CFDictionary)
    else {
        throw NormalizationError.invalidImage
    }

    let side = max(
        1,
        Int((Double(min(image.width, image.height)) * cropScale).rounded())
    )
    let crop = CGRect(
        x: (image.width - side) / 2,
        y: (image.height - side) / 2,
        width: side,
        height: side
    )
    guard let square = image.cropping(to: crop) else {
        throw NormalizationError.invalidImage
    }

    var rgba = [UInt8](repeating: 0, count: size * size * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: &rgba,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NormalizationError.invalidImage
    }
    context.interpolationQuality = .high
    context.setBlendMode(.copy)
    context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))

    return stride(from: 0, to: rgba.count, by: 4).map { index in
        let red = Int(rgba[index])
        let green = Int(rgba[index + 1])
        let blue = Int(rgba[index + 2])
        return UInt8((54 * red + 183 * green + 19 * blue + 128) >> 8)
    }
}

func normalizedTip(_ source: [UInt8]) -> [UInt8] {
    let lower = Int(percentile(source, fraction: 0.02))
    let upper = max(lower + 1, Int(percentile(source, fraction: 0.995)))
    return source.map { value in
        let expanded = (Int(value) - lower) * 255 / (upper - lower)
        return UInt8(min(255, max(0, expanded)))
    }
}

func illuminationCorrected(_ source: [UInt8], size: Int) -> [UInt8] {
    let radius = max(2, size / 16)
    var horizontal = [Int](repeating: 0, count: source.count)
    for y in 0..<size {
        var prefix = [Int](repeating: 0, count: size + 1)
        for x in 0..<size {
            prefix[x + 1] = prefix[x] + Int(source[y * size + x])
        }
        for x in 0..<size {
            let lower = max(0, x - radius)
            let upper = min(size - 1, x + radius)
            horizontal[y * size + x] = (prefix[upper + 1] - prefix[lower])
                / (upper - lower + 1)
        }
    }
    var blurred = [Int](repeating: 0, count: source.count)
    for x in 0..<size {
        var prefix = [Int](repeating: 0, count: size + 1)
        for y in 0..<size {
            prefix[y + 1] = prefix[y] + horizontal[y * size + x]
        }
        for y in 0..<size {
            let lower = max(0, y - radius)
            let upper = min(size - 1, y + radius)
            blurred[y * size + x] = (prefix[upper + 1] - prefix[lower])
                / (upper - lower + 1)
        }
    }
    return source.indices.map { index in
        let corrected = 192 + (Int(source[index]) - blurred[index]) * 2
        return UInt8(min(255, max(0, corrected)))
    }
}

func normalizedSeamlessGrain(_ source: [UInt8], size: Int) -> [UInt8] {
    precondition(size >= 4 && size.isMultiple(of: 2))
    let corrected = illuminationCorrected(source, size: size)
    let lower = Int(percentile(corrected, fraction: 0.01))
    let upper = max(lower + 1, Int(percentile(corrected, fraction: 0.99)))
    var result = corrected.map { value in
        let expanded = (Int(value) - lower) * 159 / (upper - lower) + 96
        return UInt8(min(255, max(96, expanded)))
    }

    let blendWidth = max(2, size / 8)
    for y in 0..<size {
        for inset in 0..<blendWidth {
            let left = y * size + inset
            let right = y * size + (size - 1 - inset)
            let fraction = Double(blendWidth - 1 - inset)
                / Double(blendWidth - 1)
            let average = (Double(result[left]) + Double(result[right])) * 0.5
            result[left] = UInt8((
                Double(result[left]) * (1 - fraction) + average * fraction
            ).rounded())
            result[right] = UInt8((
                Double(result[right]) * (1 - fraction) + average * fraction
            ).rounded())
        }
    }
    for x in 0..<size {
        for inset in 0..<blendWidth {
            let top = inset * size + x
            let bottom = (size - 1 - inset) * size + x
            let fraction = Double(blendWidth - 1 - inset)
                / Double(blendWidth - 1)
            let average = (Double(result[top]) + Double(result[bottom])) * 0.5
            result[top] = UInt8((
                Double(result[top]) * (1 - fraction) + average * fraction
            ).rounded())
            result[bottom] = UInt8((
                Double(result[bottom]) * (1 - fraction) + average * fraction
            ).rounded())
        }
    }
    return result
}

func pngData(bytes: [UInt8], size: Int) throws -> Data {
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
              width: size,
              height: size,
              bitsPerComponent: 8,
              bitsPerPixel: 8,
              bytesPerRow: size,
              space: CGColorSpaceCreateDeviceGray(),
              bitmapInfo: CGBitmapInfo(rawValue: 0),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          )
    else {
        throw NormalizationError.outputCreation
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NormalizationError.outputCreation
    }
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyOrientation: 1,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw NormalizationError.outputCreation
    }
    return output as Data
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 6,
          let mode = NormalizationMode(rawValue: arguments[1])
    else {
        throw NormalizationError.usage
    }
    guard let size = Int(arguments[2]), size > 0,
          mode != .grain || (size >= 4 && size.isMultiple(of: 2))
    else {
        throw NormalizationError.invalidSize
    }
    let input = URL(fileURLWithPath: arguments[3])
    let pngOutput = URL(fileURLWithPath: arguments[4])
    let r8Output = URL(fileURLWithPath: arguments[5])
    let decoded = try decodeSquareLuminance(
        url: input,
        size: size,
        cropScale: mode == .grain ? 0.35 : 1
    )
    let normalized = switch mode {
    case .tip:
        normalizedTip(decoded)
    case .grain:
        normalizedSeamlessGrain(decoded, size: size)
    }
    try pngData(bytes: normalized, size: size).write(
        to: pngOutput,
        options: .atomic
    )
    try Data(normalized).write(to: r8Output, options: .atomic)
    print("normalized \(mode.rawValue) \(size)x\(size) \(input.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(64)
}
