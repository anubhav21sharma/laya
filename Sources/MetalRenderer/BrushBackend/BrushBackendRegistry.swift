import PatternEngine

public struct BrushBackendRegistryKey:
    Comparable, Equatable, Hashable, Sendable
{
    public let kind: BrushBackendKind
    public let schemaVersion: UInt16

    public init(kind: BrushBackendKind, schemaVersion: UInt16) {
        self.kind = kind
        self.schemaVersion = schemaVersion
    }

    public static func < (
        lhs: BrushBackendRegistryKey,
        rhs: BrushBackendRegistryKey
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.schemaVersion < rhs.schemaVersion
    }
}

public enum BrushBackendCompilerFamily:
    String, Equatable, Hashable, Sendable
{
    case deposition
    case continuousRibbon
}

public enum BrushBackendEncoderFamily:
    String, Equatable, Hashable, Sendable
{
    case instancedDeposition
    case continuousRibbon
}

public struct BrushBackendCapabilities:
    OptionSet, Equatable, Hashable, Sendable
{
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let destinationSampling = Self(rawValue: 1 << 0)
    public static let secondaryColorSource = Self(rawValue: 1 << 1)
}

public enum BrushBackendActivation:
    String, Equatable, Hashable, Sendable
{
    case available
    case internalOnly
}

public struct BrushBackendRegistration: Equatable, Hashable, Sendable {
    public let key: BrushBackendRegistryKey
    public let compilerFamily: BrushBackendCompilerFamily
    public let encoderFamily: BrushBackendEncoderFamily
    public let declaredCapabilities: BrushBackendCapabilities
    public let implementedCapabilities: BrushBackendCapabilities
    public let activation: BrushBackendActivation

    public init(
        key: BrushBackendRegistryKey,
        compilerFamily: BrushBackendCompilerFamily,
        encoderFamily: BrushBackendEncoderFamily,
        declaredCapabilities: BrushBackendCapabilities,
        implementedCapabilities: BrushBackendCapabilities,
        activation: BrushBackendActivation
    ) {
        self.key = key
        self.compilerFamily = compilerFamily
        self.encoderFamily = encoderFamily
        self.declaredCapabilities = declaredCapabilities
        self.implementedCapabilities = implementedCapabilities
        self.activation = activation
    }
}

public enum BrushBackendRegistryError: Error, Equatable, Sendable {
    case duplicateRegistration(BrushBackendRegistryKey)
    case implementedCapabilitiesNotDeclared(BrushBackendRegistryKey)
    case unknownBackend(kind: BrushBackendKind, schemaVersion: UInt16)
    case unsupportedSchema(
        kind: BrushBackendKind,
        requested: UInt16,
        supported: [UInt16]
    )
}

/// Immutable application-owned table of compile-time brush backends.
///
/// Registrations are pure values. Brush packages can select an existing enum
/// kind and schema version, but cannot register code, symbols, types, or
/// dynamic libraries.
public struct BrushBackendRegistry: Equatable, Sendable {
    public let registrations: [BrushBackendRegistration]

    public init(registrations: [BrushBackendRegistration]) throws {
        var seen = Set<BrushBackendRegistryKey>()
        for registration in registrations {
            guard seen.insert(registration.key).inserted else {
                throw BrushBackendRegistryError.duplicateRegistration(
                    registration.key
                )
            }
            guard registration.implementedCapabilities.rawValue
                    & ~registration.declaredCapabilities.rawValue == 0
            else {
                throw BrushBackendRegistryError
                    .implementedCapabilitiesNotDeclared(registration.key)
            }
        }
        self.registrations = registrations.sorted { $0.key < $1.key }
    }

    public func registration(
        for kind: BrushBackendKind,
        schemaVersion: UInt16
    ) throws -> BrushBackendRegistration {
        let key = BrushBackendRegistryKey(
            kind: kind,
            schemaVersion: schemaVersion
        )
        if let registration = registrations.first(where: { $0.key == key }) {
            return registration
        }
        let supported = registrations.compactMap { registration in
            registration.key.kind == kind
                ? registration.key.schemaVersion
                : nil
        }
        guard !supported.isEmpty else {
            throw BrushBackendRegistryError.unknownBackend(
                kind: kind,
                schemaVersion: schemaVersion
            )
        }
        throw BrushBackendRegistryError.unsupportedSchema(
            kind: kind,
            requested: schemaVersion,
            supported: supported
        )
    }

    public static let nativeSchema3: BrushBackendRegistry = {
        do {
            return try BrushBackendRegistry(registrations: [
                BrushBackendRegistration(
                    key: BrushBackendRegistryKey(
                        kind: .deposition,
                        schemaVersion: 3
                    ),
                    compilerFamily: .deposition,
                    encoderFamily: .instancedDeposition,
                    declaredCapabilities: [],
                    implementedCapabilities: [],
                    activation: .available
                ),
                BrushBackendRegistration(
                    key: BrushBackendRegistryKey(
                        kind: .canvasInteraction,
                        schemaVersion: 3
                    ),
                    compilerFamily: .continuousRibbon,
                    encoderFamily: .continuousRibbon,
                    declaredCapabilities: [.destinationSampling],
                    implementedCapabilities: [],
                    activation: .internalOnly
                ),
            ])
        } catch {
            preconditionFailure("Invalid native brush backend registry: \(error)")
        }
    }()
}
