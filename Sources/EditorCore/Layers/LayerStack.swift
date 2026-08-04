import Foundation

public enum LayerBlendMode: UInt8, CaseIterable, Equatable, Sendable {
    case normal
    case multiply
    case screen
}

public enum LayerStackError: Error, Equatable, Sendable {
    case emptyStack
    case maximumLayerCountExceeded(Int)
    case duplicateLayerID(UUID)
    case activeLayerMissing(UUID)
    case layerMissing(UUID)
    case invalidName
    case invalidOpacity
    case invalidOrder(Int)
    case cannotDeleteOnlyLayer
    case activeLayerLocked(UUID)
    case invalidRestoration
}

public struct LayerDescriptor: Equatable, Sendable {
    public static let maximumNameLength = 256

    public let id: UUID
    public let name: String
    public let isVisible: Bool
    public let opacity: Float
    public let isLocked: Bool
    public let blendMode: LayerBlendMode

    public init(
        id: UUID,
        name: String,
        isVisible: Bool = true,
        opacity: Float = 1,
        isLocked: Bool = false,
        blendMode: LayerBlendMode = .normal
    ) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= Self.maximumNameLength
        else {
            throw LayerStackError.invalidName
        }
        guard opacity.isFinite, (0...1).contains(opacity) else {
            throw LayerStackError.invalidOpacity
        }
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
        self.isLocked = isLocked
        self.blendMode = blendMode
    }
}

public struct LayerRemoval: Equatable, Sendable {
    public let descriptor: LayerDescriptor
    public let order: Int
    public let activeLayerIDBefore: UUID
    public let activeLayerIDAfter: UUID

    public init(
        descriptor: LayerDescriptor,
        order: Int,
        activeLayerIDBefore: UUID,
        activeLayerIDAfter: UUID
    ) {
        self.descriptor = descriptor
        self.order = order
        self.activeLayerIDBefore = activeLayerIDBefore
        self.activeLayerIDAfter = activeLayerIDAfter
    }
}

public struct LayerStack: Equatable, Sendable {
    public static let maximumLayerCount = 8
    public static let compatibilityLayerID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!

    public private(set) var layers: [LayerDescriptor]
    public private(set) var activeLayerID: UUID

    public init(
        layers: [LayerDescriptor],
        activeLayerID: UUID
    ) throws {
        guard !layers.isEmpty else { throw LayerStackError.emptyStack }
        guard layers.count <= Self.maximumLayerCount else {
            throw LayerStackError.maximumLayerCountExceeded(
                Self.maximumLayerCount
            )
        }
        var identifiers = Set<UUID>()
        for layer in layers where !identifiers.insert(layer.id).inserted {
            throw LayerStackError.duplicateLayerID(layer.id)
        }
        guard identifiers.contains(activeLayerID) else {
            throw LayerStackError.activeLayerMissing(activeLayerID)
        }
        self.layers = layers
        self.activeLayerID = activeLayerID
    }

    public static func compatibilityDefault() -> LayerStack {
        let descriptor = try! LayerDescriptor(
            id: compatibilityLayerID,
            name: "Layer 1"
        )
        return try! LayerStack(
            layers: [descriptor],
            activeLayerID: descriptor.id
        )
    }

    public var orderedLayerIDs: [UUID] { layers.map(\.id) }

    public var snapshot: LayerStackSnapshot {
        LayerStackSnapshot(layers: layers, activeLayerID: activeLayerID)
    }

    public init(snapshot: LayerStackSnapshot) throws {
        try self.init(
            layers: snapshot.layers,
            activeLayerID: snapshot.activeLayerID
        )
    }

    public func layer(id: UUID) -> LayerDescriptor? {
        layers.first { $0.id == id }
    }

    public func activeLayerForRasterMutation() throws -> LayerDescriptor {
        guard let active = layer(id: activeLayerID) else {
            throw LayerStackError.activeLayerMissing(activeLayerID)
        }
        guard !active.isLocked else {
            throw LayerStackError.activeLayerLocked(active.id)
        }
        return active
    }

    public mutating func add(
        _ descriptor: LayerDescriptor,
        at order: Int
    ) throws {
        guard layer(id: descriptor.id) == nil else {
            throw LayerStackError.duplicateLayerID(descriptor.id)
        }
        guard layers.count < Self.maximumLayerCount else {
            throw LayerStackError.maximumLayerCountExceeded(
                Self.maximumLayerCount
            )
        }
        guard (0...layers.count).contains(order) else {
            throw LayerStackError.invalidOrder(order)
        }
        layers.insert(descriptor, at: order)
    }

    @discardableResult
    public mutating func delete(_ id: UUID) throws -> LayerRemoval {
        guard layers.count > 1 else {
            throw LayerStackError.cannotDeleteOnlyLayer
        }
        guard let order = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerStackError.layerMissing(id)
        }
        let activeBefore = activeLayerID
        let removed = layers.remove(at: order)
        if activeBefore == id {
            activeLayerID = layers[min(order, layers.count - 1)].id
        }
        return LayerRemoval(
            descriptor: removed,
            order: order,
            activeLayerIDBefore: activeBefore,
            activeLayerIDAfter: activeLayerID
        )
    }

    public mutating func restore(_ removal: LayerRemoval) throws {
        guard layers.count < Self.maximumLayerCount,
              layer(id: removal.descriptor.id) == nil,
              (0...layers.count).contains(removal.order),
              activeLayerID == removal.activeLayerIDAfter
        else {
            throw LayerStackError.invalidRestoration
        }
        let activeBeforeExists = removal.activeLayerIDBefore
            == removal.descriptor.id
            || layer(id: removal.activeLayerIDBefore) != nil
        guard activeBeforeExists else {
            throw LayerStackError.invalidRestoration
        }
        layers.insert(removal.descriptor, at: removal.order)
        activeLayerID = removal.activeLayerIDBefore
    }

    public mutating func move(_ id: UUID, to order: Int) throws {
        guard let oldOrder = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerStackError.layerMissing(id)
        }
        guard layers.indices.contains(order) else {
            throw LayerStackError.invalidOrder(order)
        }
        guard oldOrder != order else { return }
        let descriptor = layers.remove(at: oldOrder)
        layers.insert(descriptor, at: order)
    }

    public mutating func setActiveLayer(_ id: UUID) throws {
        guard layer(id: id) != nil else {
            throw LayerStackError.layerMissing(id)
        }
        activeLayerID = id
    }

    public mutating func rename(_ id: UUID, to name: String) throws {
        try replace(id) { layer in
            try LayerDescriptor(
                id: layer.id,
                name: name,
                isVisible: layer.isVisible,
                opacity: layer.opacity,
                isLocked: layer.isLocked,
                blendMode: layer.blendMode
            )
        }
    }

    public mutating func setVisibility(
        _ id: UUID,
        isVisible: Bool
    ) throws {
        try replace(id) { layer in
            try LayerDescriptor(
                id: layer.id,
                name: layer.name,
                isVisible: isVisible,
                opacity: layer.opacity,
                isLocked: layer.isLocked,
                blendMode: layer.blendMode
            )
        }
    }

    public mutating func setOpacity(_ id: UUID, opacity: Float) throws {
        try replace(id) { layer in
            try LayerDescriptor(
                id: layer.id,
                name: layer.name,
                isVisible: layer.isVisible,
                opacity: opacity,
                isLocked: layer.isLocked,
                blendMode: layer.blendMode
            )
        }
    }

    public mutating func setLock(_ id: UUID, isLocked: Bool) throws {
        try replace(id) { layer in
            try LayerDescriptor(
                id: layer.id,
                name: layer.name,
                isVisible: layer.isVisible,
                opacity: layer.opacity,
                isLocked: isLocked,
                blendMode: layer.blendMode
            )
        }
    }

    public mutating func setBlendMode(
        _ id: UUID,
        blendMode: LayerBlendMode
    ) throws {
        try replace(id) { layer in
            try LayerDescriptor(
                id: layer.id,
                name: layer.name,
                isVisible: layer.isVisible,
                opacity: layer.opacity,
                isLocked: layer.isLocked,
                blendMode: blendMode
            )
        }
    }

    private mutating func replace(
        _ id: UUID,
        transform: (LayerDescriptor) throws -> LayerDescriptor
    ) throws {
        guard let index = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerStackError.layerMissing(id)
        }
        let replacement = try transform(layers[index])
        layers[index] = replacement
    }
}
