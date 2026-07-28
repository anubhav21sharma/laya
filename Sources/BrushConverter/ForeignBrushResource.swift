import Foundation

public enum ForeignBrushResourceRole:
    String, Codable, CaseIterable, Sendable
{
    case shape
    case grain
    case preview
    case auxiliary
    case unknown
}

public enum ForeignBrushChannelModel:
    String, Codable, CaseIterable, Sendable
{
    case grayscale
    case grayscaleAlpha
    case rgb
    case rgba
}

public enum ForeignBrushColorInterpretation:
    String, Codable, CaseIterable, Sendable
{
    case linear
    case sRGB
    case displayP3
    case unspecified
}

public enum ForeignBrushImageOrientation:
    String, Codable, CaseIterable, Sendable
{
    case up
    case down
    case left
    case right
    case upMirrored
    case downMirrored
    case leftMirrored
    case rightMirrored
}

public struct ForeignBrushResourceDescriptor:
    Codable, Equatable, Sendable
{
    public let id: String
    public let role: ForeignBrushResourceRole
    public let containerLocation: String
    public let mediaType: String
    public let contentSHA256: String
    public let encodedByteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let channelModel: ForeignBrushChannelModel
    public let colorInterpretation: ForeignBrushColorInterpretation
    public let inverted: Bool
    public let orientation: ForeignBrushImageOrientation

    public init(
        id: String,
        role: ForeignBrushResourceRole,
        containerLocation: String,
        mediaType: String,
        contentSHA256: String,
        encodedByteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        channelModel: ForeignBrushChannelModel,
        colorInterpretation: ForeignBrushColorInterpretation,
        inverted: Bool,
        orientation: ForeignBrushImageOrientation
    ) throws {
        try ForeignBrushValidator.string(id, field: "resource.id")
        try ForeignBrushValidator.location(
            containerLocation,
            field: "resource.containerLocation"
        )
        try ForeignBrushValidator.mediaType(mediaType)
        try ForeignBrushValidator.sha256(
            contentSHA256,
            field: "resource.contentSHA256"
        )
        guard (1...ForeignBrushLimits.maximumEncodedResourceBytes)
            .contains(encodedByteCount)
        else {
            throw ForeignBrushValidationError.outOfRange(
                "resource.encodedByteCount"
            )
        }
        guard (1...ForeignBrushLimits.maximumSourceImageDimension)
            .contains(pixelWidth)
        else {
            throw ForeignBrushValidationError.outOfRange(
                "resource.pixelWidth"
            )
        }
        guard (1...ForeignBrushLimits.maximumSourceImageDimension)
            .contains(pixelHeight)
        else {
            throw ForeignBrushValidationError.outOfRange(
                "resource.pixelHeight"
            )
        }
        self.id = id
        self.role = role
        self.containerLocation = containerLocation
        self.mediaType = mediaType
        self.contentSHA256 = contentSHA256
        self.encodedByteCount = encodedByteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.channelModel = channelModel
        self.colorInterpretation = colorInterpretation
        self.inverted = inverted
        self.orientation = orientation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case containerLocation
        case mediaType
        case contentSHA256
        case encodedByteCount
        case pixelWidth
        case pixelHeight
        case channelModel
        case colorInterpretation
        case inverted
        case orientation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            role: container.decode(
                ForeignBrushResourceRole.self,
                forKey: .role
            ),
            containerLocation: container.decode(
                String.self,
                forKey: .containerLocation
            ),
            mediaType: container.decode(String.self, forKey: .mediaType),
            contentSHA256: container.decode(
                String.self,
                forKey: .contentSHA256
            ),
            encodedByteCount: container.decode(
                Int.self,
                forKey: .encodedByteCount
            ),
            pixelWidth: container.decode(Int.self, forKey: .pixelWidth),
            pixelHeight: container.decode(Int.self, forKey: .pixelHeight),
            channelModel: container.decode(
                ForeignBrushChannelModel.self,
                forKey: .channelModel
            ),
            colorInterpretation: container.decode(
                ForeignBrushColorInterpretation.self,
                forKey: .colorInterpretation
            ),
            inverted: container.decode(Bool.self, forKey: .inverted),
            orientation: container.decode(
                ForeignBrushImageOrientation.self,
                forKey: .orientation
            )
        )
    }
}
