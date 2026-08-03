import Foundation

public struct BrushSensorNormalizationDefinition:
    Codable, Equatable, Sendable
{
    public let fullScaleWorldVelocity: Float
    public let minimumVelocityDeltaTime: TimeInterval
    public let fullScaleStrokeAge: TimeInterval
    public let fullScaleStrokeDistanceInDiameters: Float

    public init(
        fullScaleWorldVelocity: Float,
        minimumVelocityDeltaTime: TimeInterval,
        fullScaleStrokeAge: TimeInterval,
        fullScaleStrokeDistanceInDiameters: Float
    ) {
        self.fullScaleWorldVelocity = fullScaleWorldVelocity
        self.minimumVelocityDeltaTime = minimumVelocityDeltaTime
        self.fullScaleStrokeAge = fullScaleStrokeAge
        self.fullScaleStrokeDistanceInDiameters =
            fullScaleStrokeDistanceInDiameters
    }
}

public enum BrushDynamicOutput:
    String, CaseIterable, Codable, Hashable, Sendable
{
    case size, flow, opacity, spacing, rotation, scatter, hardness, grain
    case offsetX, offsetY, hue, saturation, brightness, secondaryColorMix
}

public enum BrushResponseOperation: String, Codable, Equatable, Sendable {
    case replace, multiply, add, minimum, maximum
}

public struct BrushResponseTermDefinition: Codable, Equatable, Sendable {
    public let input: BrushDynamicsInput
    public let response: BrushResponseDefinition
    public let inputInverted: Bool
    public let missingInputValue: Float
    public let responseScale: Float
    public let responseOffset: Float
    public let responseLowerClamp: Float
    public let responseUpperClamp: Float
    public let jitter: Float
    public let operation: BrushResponseOperation

    public init(
        input: BrushDynamicsInput,
        response: BrushResponseDefinition,
        inputInverted: Bool,
        missingInputValue: Float,
        responseScale: Float,
        responseOffset: Float,
        responseLowerClamp: Float,
        responseUpperClamp: Float,
        jitter: Float,
        operation: BrushResponseOperation
    ) {
        self.input = input
        self.response = response
        self.inputInverted = inputInverted
        self.missingInputValue = missingInputValue
        self.responseScale = responseScale
        self.responseOffset = responseOffset
        self.responseLowerClamp = responseLowerClamp
        self.responseUpperClamp = responseUpperClamp
        self.jitter = jitter
        self.operation = operation
    }
}

public struct BrushOutputProgramDefinition: Codable, Equatable, Sendable {
    public let baseValue: Float
    public let terms: [BrushResponseTermDefinition]

    public init(baseValue: Float, terms: [BrushResponseTermDefinition]) {
        self.baseValue = baseValue
        self.terms = terms
    }
}

public struct BrushSensorProgramDefinition: Codable, Equatable, Sendable {
    public let outputs: [BrushDynamicOutput: BrushOutputProgramDefinition]

    public init(
        outputs: [BrushDynamicOutput: BrushOutputProgramDefinition]
    ) {
        self.outputs = outputs
    }
}

public enum BrushStabilizationDefinition: Codable, Equatable, Sendable {
    case none
    case weightedWindow(distance: Float)
    case delayed(distance: Float)

    private enum CodingKeys: String, CodingKey { case kind, distance }
    private enum Kind: String, Codable { case none, weightedWindow, delayed }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .weightedWindow:
            self = .weightedWindow(
                distance: try container.decode(Float.self, forKey: .distance)
            )
        case .delayed:
            self = .delayed(
                distance: try container.decode(Float.self, forKey: .distance)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case let .weightedWindow(distance):
            try container.encode(Kind.weightedWindow, forKey: .kind)
            try container.encode(distance, forKey: .distance)
        case let .delayed(distance):
            try container.encode(Kind.delayed, forKey: .kind)
            try container.encode(distance, forKey: .distance)
        }
    }
}

public struct BrushDirectionDefinition: Codable, Equatable, Sendable {
    public let maximumAngularStep: Float
    public let stationaryDirection: Float

    public init(maximumAngularStep: Float, stationaryDirection: Float) {
        self.maximumAngularStep = maximumAngularStep
        self.stationaryDirection = stationaryDirection
    }
}

public enum BrushEmissionMode: String, Codable, Equatable, Sendable {
    case distance, time, distanceAndTime
}

public struct BrushEmissionDefinition: Codable, Equatable, Sendable {
    public let mode: BrushEmissionMode
    public let timeInterval: TimeInterval?

    public init(mode: BrushEmissionMode, timeInterval: TimeInterval?) {
        self.mode = mode
        self.timeInterval = timeInterval
    }
}

extension BrushTipSupportDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, minX, maxX, minY, maxY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .analyticEllipse:
            self = .analyticEllipse
        case .analyticRectangle:
            self = .analyticRectangle
        case .normalizedBounds:
            self = try .normalizedBounds(
                minX: container.decode(Float.self, forKey: .minX),
                maxX: container.decode(Float.self, forKey: .maxX),
                minY: container.decode(Float.self, forKey: .minY),
                maxY: container.decode(Float.self, forKey: .maxY)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if let bounds {
            try container.encode(bounds.minX, forKey: .minX)
            try container.encode(bounds.maxX, forKey: .maxX)
            try container.encode(bounds.minY, forKey: .minY)
            try container.encode(bounds.maxY, forKey: .maxY)
        }
    }
}

extension BrushTipSupportDefinition.Kind: Codable {}
