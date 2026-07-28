import Foundation

public enum ForeignBrushSettingUnit: String, Codable, CaseIterable, Sendable {
    case unitless
    case normalized
    case pixels
    case percent
    case degrees
    case radians
    case seconds
    case pointsPerSecond
    case count
    case sRGB
}

public enum ForeignBrushSettingDomain:
    String, Codable, CaseIterable, Sendable
{
    case boolean
    case integer
    case scalar
    case token
    case vector
    case curve
    case color
    case resource
}

public struct ForeignBrushCurvePoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        try ForeignBrushValidator.finite(x, field: "curve.x")
        try ForeignBrushValidator.finite(y, field: "curve.y")
        self.x = Self.canonicalZero(x)
        self.y = Self.canonicalZero(y)
    }

    private static func canonicalZero(_ value: Double) -> Double {
        value == 0 ? 0 : value
    }

    private enum CodingKeys: String, CodingKey {
        case x, y
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x),
            y: container.decode(Double.self, forKey: .y)
        )
    }
}

public struct ForeignBrushColor: Codable, Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double
    ) throws {
        for (field, value) in [
            ("color.red", red),
            ("color.green", green),
            ("color.blue", blue),
            ("color.alpha", alpha),
        ] {
            try ForeignBrushValidator.finite(value, field: field)
            guard (0...1).contains(value) else {
                throw ForeignBrushValidationError.outOfRange(field)
            }
        }
        self.red = Self.canonicalZero(red)
        self.green = Self.canonicalZero(green)
        self.blue = Self.canonicalZero(blue)
        self.alpha = Self.canonicalZero(alpha)
    }

    private static func canonicalZero(_ value: Double) -> Double {
        value == 0 ? 0 : value
    }

    private enum CodingKeys: String, CodingKey {
        case red, green, blue, alpha
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            red: container.decode(Double.self, forKey: .red),
            green: container.decode(Double.self, forKey: .green),
            blue: container.decode(Double.self, forKey: .blue),
            alpha: container.decode(Double.self, forKey: .alpha)
        )
    }
}

public enum ForeignBrushSettingValue: Codable, Equatable, Sendable {
    case boolean(Bool)
    case integer(Int64)
    case scalar(Double)
    case token(String)
    case vector([Double])
    case curve([ForeignBrushCurvePoint])
    case color(ForeignBrushColor)
    case resourceReference(String)

    var domain: ForeignBrushSettingDomain {
        switch self {
        case .boolean: .boolean
        case .integer: .integer
        case .scalar: .scalar
        case .token: .token
        case .vector: .vector
        case .curve: .curve
        case .color: .color
        case .resourceReference: .resource
        }
    }

    var resourceReference: String? {
        guard case let .resourceReference(identifier) = self else {
            return nil
        }
        return identifier
    }

    func validate() throws {
        switch self {
        case .boolean, .integer:
            break
        case let .scalar(value):
            try ForeignBrushValidator.finite(
                value,
                field: "setting.value.scalar"
            )
        case let .token(value):
            try ForeignBrushValidator.string(
                value,
                field: "setting.value.token"
            )
        case let .vector(values):
            try ForeignBrushValidator.count(
                values.count,
                field: "setting.value.vector",
                maximum: ForeignBrushLimits.maximumVectorComponents,
                minimum: 1
            )
            for value in values {
                try ForeignBrushValidator.finite(
                    value,
                    field: "setting.value.vector"
                )
            }
        case let .curve(points):
            try ForeignBrushValidator.count(
                points.count,
                field: "setting.value.curve",
                maximum: ForeignBrushLimits.maximumCurvePointsPerSetting,
                minimum: 2
            )
            let coordinates = points.map(\.x)
            guard coordinates == coordinates.sorted() else {
                throw ForeignBrushValidationError.unsorted(
                    "setting.value.curve"
                )
            }
            for index in coordinates.indices.dropFirst()
            where coordinates[index - 1] == coordinates[index] {
                throw ForeignBrushValidationError.duplicate(
                    field: "setting.value.curve",
                    value: String(coordinates[index])
                )
            }
            for point in points {
                try ForeignBrushValidator.finite(
                    point.x,
                    field: "setting.value.curve"
                )
                try ForeignBrushValidator.finite(
                    point.y,
                    field: "setting.value.curve"
                )
            }
        case let .color(color):
            _ = try ForeignBrushColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
        case let .resourceReference(identifier):
            try ForeignBrushValidator.string(
                identifier,
                field: "setting.value.resourceReference"
            )
        }
    }

    func canonicalized() -> Self {
        switch self {
        case .boolean, .integer, .token, .resourceReference:
            return self
        case let .scalar(value):
            return .scalar(value == 0 ? 0 : value)
        case let .vector(values):
            return .vector(values.map { $0 == 0 ? 0 : $0 })
        case .curve, .color:
            return self
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    private enum Kind: String, Codable {
        case boolean
        case integer
        case scalar
        case token
        case vector
        case curve
        case color
        case resourceReference
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .scalar(value):
            try container.encode(Kind.scalar, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .token(value):
            try container.encode(Kind.token, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .vector(value):
            try container.encode(Kind.vector, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .curve(value):
            try container.encode(Kind.curve, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .color(value):
            try container.encode(Kind.color, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .resourceReference(value):
            try container.encode(Kind.resourceReference, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .scalar:
            self = .scalar(try container.decode(Double.self, forKey: .value))
        case .token:
            self = .token(try container.decode(String.self, forKey: .value))
        case .vector:
            self = .vector(
                try container.decode([Double].self, forKey: .value)
            )
        case .curve:
            self = .curve(
                try container.decode(
                    [ForeignBrushCurvePoint].self,
                    forKey: .value
                )
            )
        case .color:
            self = .color(
                try container.decode(ForeignBrushColor.self, forKey: .value)
            )
        case .resourceReference:
            self = .resourceReference(
                try container.decode(String.self, forKey: .value)
            )
        }
        try validate()
    }
}

public struct ForeignBrushSetting: Codable, Equatable, Sendable {
    public let semanticKey: String
    public let unit: ForeignBrushSettingUnit
    public let domain: ForeignBrushSettingDomain
    public let location: String
    public let value: ForeignBrushSettingValue

    public init(
        semanticKey: String,
        unit: ForeignBrushSettingUnit,
        domain: ForeignBrushSettingDomain,
        location: String,
        value: ForeignBrushSettingValue
    ) throws {
        try ForeignBrushValidator.semanticKey(semanticKey)
        try ForeignBrushValidator.location(
            location,
            field: "setting.location"
        )
        let canonicalValue = value.canonicalized()
        try canonicalValue.validate()
        guard canonicalValue.domain == domain else {
            throw ForeignBrushValidationError.domainMismatch(
                expected: canonicalValue.domain,
                actual: domain
            )
        }
        switch domain {
        case .boolean, .token, .resource:
            guard unit == .unitless else {
                throw ForeignBrushValidationError.unitMismatch(
                    domain: domain,
                    unit: unit
                )
            }
        case .color:
            guard unit == .sRGB else {
                throw ForeignBrushValidationError.unitMismatch(
                    domain: domain,
                    unit: unit
                )
            }
        case .integer:
            guard unit == .unitless || unit == .count else {
                throw ForeignBrushValidationError.unitMismatch(
                    domain: domain,
                    unit: unit
                )
            }
        case .scalar, .vector, .curve:
            break
        }
        self.semanticKey = semanticKey
        self.unit = unit
        self.domain = domain
        self.location = location
        self.value = canonicalValue
    }

    private enum CodingKeys: String, CodingKey {
        case semanticKey, unit, domain, location, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            semanticKey: container.decode(String.self, forKey: .semanticKey),
            unit: container.decode(
                ForeignBrushSettingUnit.self,
                forKey: .unit
            ),
            domain: container.decode(
                ForeignBrushSettingDomain.self,
                forKey: .domain
            ),
            location: container.decode(String.self, forKey: .location),
            value: container.decode(
                ForeignBrushSettingValue.self,
                forKey: .value
            )
        )
    }
}
