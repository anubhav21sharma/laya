import Foundation

public enum BrushCursorDescriptorError: Error, Equatable, Sendable {
    case invalidInput
    case invalidProfile
    case profileComponentCountMismatch
    case profileShapeCountMismatch
    case singularDeformation
    case emptyCompositeSupport
}

public enum BrushCursorTipShape: Equatable, Sendable {
    case analyticEllipse
    case analyticRectangle
    case contour([SIMD2<Float>])
}

public struct BrushCursorTipProfile: Equatable, Sendable {
    public let primary: BrushCursorTipShape
    public let secondary: BrushCursorTipShape?
    public let secondaryCombination: BrushShapeCombinationMode?

    public init(
        primary: BrushCursorTipShape,
        secondary: BrushCursorTipShape? = nil,
        secondaryCombination: BrushShapeCombinationMode? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.secondaryCombination = secondaryCombination
    }
}

public struct BrushCursorInput: Equatable, Sendable {
    public let nominalDiameter: Float
    public let pressure: Float?
    public let altitude: Float?
    public let azimuth: Float?
    public let roll: Float?
    public let tangentialPressure: Float?
    public let direction: Float
    public let deformation: Affine2D
    public let viewportScale: Float
    public let backingScale: Float

    public init(
        nominalDiameter: Float,
        pressure: Float?,
        altitude: Float?,
        azimuth: Float?,
        roll: Float?,
        tangentialPressure: Float?,
        direction: Float,
        deformation: Affine2D,
        viewportScale: Float,
        backingScale: Float
    ) throws {
        guard nominalDiameter.isFinite,
              direction.isFinite,
              viewportScale.isFinite,
              backingScale.isFinite,
              deformation.xAxis.x.isFinite,
              deformation.xAxis.y.isFinite,
              deformation.yAxis.x.isFinite,
              deformation.yAxis.y.isFinite,
              deformation.translation.x.isFinite,
              deformation.translation.y.isFinite,
              pressure?.isFinite != false,
              altitude?.isFinite != false,
              azimuth?.isFinite != false,
              roll?.isFinite != false,
              tangentialPressure?.isFinite != false,
              nominalDiameter > 0,
              viewportScale > 0,
              backingScale > 0
        else {
            throw BrushCursorDescriptorError.invalidInput
        }
        let determinant = deformation.xAxis.x * deformation.yAxis.y
            - deformation.xAxis.y * deformation.yAxis.x
        guard abs(determinant) >= Float.ulpOfOne else {
            throw BrushCursorDescriptorError.singularDeformation
        }
        self.nominalDiameter = nominalDiameter
        self.pressure = pressure
        self.altitude = altitude
        self.azimuth = azimuth
        self.roll = roll
        self.tangentialPressure = tangentialPressure
        self.direction = direction
        self.deformation = deformation
        self.viewportScale = viewportScale
        self.backingScale = backingScale
    }
}

public struct BrushCursorBounds: Equatable, Sendable {
    public let minimum: SIMD2<Float>
    public let maximum: SIMD2<Float>

    public var width: Float { maximum.x - minimum.x }
    public var height: Float { maximum.y - minimum.y }

    init(minimum: SIMD2<Float>, maximum: SIMD2<Float>) throws {
        guard minimum.x.isFinite, minimum.y.isFinite,
              maximum.x.isFinite, maximum.y.isFinite,
              minimum.x < maximum.x, minimum.y < maximum.y
        else {
            throw BrushCursorDescriptorError.emptyCompositeSupport
        }
        self.minimum = minimum
        self.maximum = maximum
    }

    func expanded(by extent: SIMD2<Float>) throws -> BrushCursorBounds {
        try BrushCursorBounds(
            minimum: minimum - extent,
            maximum: maximum + extent
        )
    }

    func union(_ other: BrushCursorBounds) throws -> BrushCursorBounds {
        try BrushCursorBounds(
            minimum: SIMD2(
                Swift.min(minimum.x, other.minimum.x),
                Swift.min(minimum.y, other.minimum.y)
            ),
            maximum: SIMD2(
                Swift.max(maximum.x, other.maximum.x),
                Swift.max(maximum.y, other.maximum.y)
            )
        )
    }

    func intersection(_ other: BrushCursorBounds) throws -> BrushCursorBounds {
        try BrushCursorBounds(
            minimum: SIMD2(
                Swift.max(minimum.x, other.minimum.x),
                Swift.max(minimum.y, other.minimum.y)
            ),
            maximum: SIMD2(
                Swift.min(maximum.x, other.maximum.x),
                Swift.min(maximum.y, other.maximum.y)
            )
        )
    }
}

public struct BrushCursorLayerDescriptor: Equatable, Sendable {
    public let shape: BrushCursorTipShape
    public let normalizedTipToLogical: Affine2D
    public let bounds: BrushCursorBounds

    public var normalizedTipToLogicalDeterminant: Float {
        normalizedTipToLogical.xAxis.x
            * normalizedTipToLogical.yAxis.y
            - normalizedTipToLogical.xAxis.y
            * normalizedTipToLogical.yAxis.x
    }

    init(shape: BrushCursorTipShape, transform: Affine2D) throws {
        self.shape = shape
        normalizedTipToLogical = transform
        bounds = try Self.bounds(shape: shape, transform: transform)
    }

    public func contains(_ point: SIMD2<Float>) -> Bool {
        let local = normalizedTipToLogical.inverted().applying(to: point)
        switch shape {
        case .analyticEllipse:
            return local.x * local.x + local.y * local.y <= 1.000_01
        case .analyticRectangle:
            return abs(local.x) <= 1.000_01 && abs(local.y) <= 1.000_01
        case let .contour(points):
            return Self.polygonContains(points, point: local)
        }
    }

    private static func bounds(
        shape: BrushCursorTipShape,
        transform: Affine2D
    ) throws -> BrushCursorBounds {
        switch shape {
        case .analyticEllipse:
            let extent = SIMD2(
                hypot(transform.xAxis.x, transform.yAxis.x),
                hypot(transform.xAxis.y, transform.yAxis.y)
            )
            return try BrushCursorBounds(
                minimum: transform.translation - extent,
                maximum: transform.translation + extent
            )
        case .analyticRectangle:
            let extent = SIMD2(
                abs(transform.xAxis.x) + abs(transform.yAxis.x),
                abs(transform.xAxis.y) + abs(transform.yAxis.y)
            )
            return try BrushCursorBounds(
                minimum: transform.translation - extent,
                maximum: transform.translation + extent
            )
        case let .contour(points):
            guard points.count >= 3,
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
            else {
                throw BrushCursorDescriptorError.invalidProfile
            }
            var minimum = SIMD2<Float>(repeating: .infinity)
            var maximum = SIMD2<Float>(repeating: -.infinity)
            for point in points {
                let transformed = transform.applying(to: point)
                minimum = SIMD2(
                    Swift.min(minimum.x, transformed.x),
                    Swift.min(minimum.y, transformed.y)
                )
                maximum = SIMD2(
                    Swift.max(maximum.x, transformed.x),
                    Swift.max(maximum.y, transformed.y)
                )
            }
            return try BrushCursorBounds(minimum: minimum, maximum: maximum)
        }
    }

    private static func polygonContains(
        _ points: [SIMD2<Float>],
        point: SIMD2<Float>
    ) -> Bool {
        var inside = false
        var previous = points[points.count - 1]
        for current in points {
            if pointLiesOnSegment(point, start: previous, end: current) {
                return true
            }
            let crosses = (current.y > point.y) != (previous.y > point.y)
            if crosses {
                let crossingX = (previous.x - current.x)
                    * (point.y - current.y)
                    / (previous.y - current.y)
                    + current.x
                if point.x < crossingX {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }

    private static func pointLiesOnSegment(
        _ point: SIMD2<Float>,
        start: SIMD2<Float>,
        end: SIMD2<Float>
    ) -> Bool {
        let segment = end - start
        let relative = point - start
        let cross = segment.x * relative.y - segment.y * relative.x
        guard abs(cross) <= 0.000_01 else { return false }
        let dot = relative.x * segment.x + relative.y * segment.y
        let squaredLength = segment.x * segment.x + segment.y * segment.y
        return dot >= -0.000_01 && dot <= squaredLength + 0.000_01
    }
}

public struct BrushCursorComponentDescriptor: Equatable, Sendable {
    public let identifier: BrushComponentIdentifier
    public let ordinal: UInt8
    public let primary: BrushCursorLayerDescriptor
    public let secondary: BrushCursorLayerDescriptor?
    public let secondaryCombination: BrushShapeCombinationMode?
    public let coreBounds: BrushCursorBounds?
    public let envelopeBounds: BrushCursorBounds?
    public let isCircle: Bool

    public func containsCore(_ point: SIMD2<Float>) -> Bool {
        guard coreBounds != nil else { return false }
        let primaryContains = primary.contains(point)
        guard let secondary else { return primaryContains }
        let secondaryContains = secondary.contains(point)
        switch secondaryCombination {
        case .replace: return secondaryContains
        case .multiply, .minimum: return primaryContains && secondaryContains
        case .maximum: return primaryContains || secondaryContains
        case nil: return primaryContains
        }
    }
}

public struct BrushCursorDescriptor: Equatable, Sendable {
    public let primaryComponent: BrushCursorComponentDescriptor
    public let secondaryComponent: BrushCursorComponentDescriptor?
    public let coreBounds: BrushCursorBounds
    public let envelopeBounds: BrushCursorBounds
    public let isCircle: Bool

    public static func evaluate(
        program: BrushProgram,
        profile: BrushCursorTipProfile,
        input: BrushCursorInput
    ) throws -> BrushCursorDescriptor {
        guard program.secondaryComponent == nil else {
            throw BrushCursorDescriptorError.profileComponentCountMismatch
        }
        return try evaluate(
            program: program,
            primaryProfile: profile,
            secondaryProfile: nil,
            input: input
        )
    }

    public static func evaluate(
        program: BrushProgram,
        primaryProfile: BrushCursorTipProfile,
        secondaryProfile: BrushCursorTipProfile?,
        input: BrushCursorInput
    ) throws -> BrushCursorDescriptor {
        guard (program.secondaryComponent == nil) == (secondaryProfile == nil)
        else {
            throw BrushCursorDescriptorError.profileComponentCountMismatch
        }

        let sample = cursorSample(input: input)
        let primaryComponent = try evaluateComponent(
            program: program,
            component: program.primaryComponent,
            profile: primaryProfile,
            input: input,
            sample: sample
        )
        let secondaryComponent: BrushCursorComponentDescriptor?
        if let component = program.secondaryComponent,
           let profile = secondaryProfile {
            secondaryComponent = try evaluateComponent(
                program: program,
                component: component,
                profile: profile,
                input: input,
                sample: sample
            )
        } else {
            secondaryComponent = nil
        }

        guard let coreBounds = try union(
            primaryComponent.coreBounds,
            secondaryComponent?.coreBounds
        ), let envelopeBounds = try union(
            primaryComponent.envelopeBounds,
            secondaryComponent?.envelopeBounds
        ) else {
            throw BrushCursorDescriptorError.emptyCompositeSupport
        }
        let primaryIsVisibleCircle = primaryComponent.coreBounds != nil
            && primaryComponent.isCircle
        let secondaryIsVisibleCircle = secondaryComponent?.coreBounds != nil
            && secondaryComponent?.isCircle == true
        let visibleComponentCount = (primaryComponent.coreBounds == nil ? 0 : 1)
            + (secondaryComponent?.coreBounds == nil ? 0 : 1)
        return BrushCursorDescriptor(
            primaryComponent: primaryComponent,
            secondaryComponent: secondaryComponent,
            coreBounds: coreBounds,
            envelopeBounds: envelopeBounds,
            isCircle: visibleComponentCount == 1
                && (primaryIsVisibleCircle || secondaryIsVisibleCircle)
        )
    }

    public func containsCore(_ point: SIMD2<Float>) -> Bool {
        primaryComponent.containsCore(point)
            || secondaryComponent?.containsCore(point) == true
    }

    private static func evaluateComponent(
        program: BrushProgram,
        component: BrushComponentProgram,
        profile: BrushCursorTipProfile,
        input: BrushCursorInput,
        sample: InterpolatedStrokeSample
    ) throws -> BrushCursorComponentDescriptor {
        try validate(profile: profile, component: component)
        let stageC = component.stageC
        let context = BrushStrokeContext(
            nominalDiameter: input.nominalDiameter,
            color: .black,
            direction: input.direction,
            strokeAge: 0,
            traveledDistance: 0,
            ordinal: 0,
            isPredicted: false,
            speedReference: stageC.normalization.fullScaleWorldVelocity,
            ageReference: Float(stageC.normalization.fullScaleStrokeAge),
            distanceReference: input.nominalDiameter
                * stageC.normalization.fullScaleStrokeDistanceInDiameters
        )
        let evaluation = BrushDynamicsEngine().evaluateCursor(
            sample: sample,
            context: context,
            program: program,
            component: component
        )
        let definition = component.definition
        let primaryAuthored = authoredShapeFrame(
            definition.coverage.shapes[0]
        )
        let tipToWorld = primaryAuthored.inverted().concatenating(
            evaluation.dab.brushToWorld
        )
        let logicalScale = input.viewportScale / input.backingScale
        let scaleTransform = Affine2D(
            xAxis: SIMD2(logicalScale, 0),
            yAxis: SIMD2(0, logicalScale),
            translation: .zero
        )
        func logicalTransform(_ authored: Affine2D) -> Affine2D {
            authored
                .concatenating(tipToWorld)
                .concatenating(input.deformation)
                .concatenating(scaleTransform)
        }
        let primary = try BrushCursorLayerDescriptor(
            shape: profile.primary,
            transform: logicalTransform(primaryAuthored)
        )
        let secondary: BrushCursorLayerDescriptor?
        if let secondaryShape = profile.secondary {
            secondary = try BrushCursorLayerDescriptor(
                shape: secondaryShape,
                transform: logicalTransform(authoredShapeFrame(
                    definition.coverage.shapes[1]
                ))
            )
        } else {
            secondary = nil
        }
        let coreBounds = try compositeBounds(
            primary: primary,
            secondary: secondary,
            combination: profile.secondaryCombination
        )
        let placement = evaluation.maximumPlacementOffset * logicalScale
        let deformation = input.deformation
        let placementExtent = SIMD2(
            placement * (
                abs(deformation.xAxis.x) + abs(deformation.yAxis.x)
            ),
            placement * (
                abs(deformation.xAxis.y) + abs(deformation.yAxis.y)
            )
        )
        return BrushCursorComponentDescriptor(
            identifier: definition.identifier,
            ordinal: definition.ordinal,
            primary: primary,
            secondary: secondary,
            secondaryCombination: profile.secondaryCombination,
            coreBounds: coreBounds,
            envelopeBounds: try coreBounds?.expanded(by: placementExtent),
            isCircle: coreBounds != nil
                && secondary == nil
                && isCircularEllipse(primary)
        )
    }

    private static func cursorSample(
        input: BrushCursorInput
    ) -> InterpolatedStrokeSample {
        var capabilities: StrokeInputCapabilities = []
        if input.pressure != nil { capabilities.insert(.pressure) }
        if input.altitude != nil { capabilities.insert(.altitude) }
        if input.azimuth != nil { capabilities.insert(.azimuth) }
        if input.roll != nil { capabilities.insert(.roll) }
        if input.tangentialPressure != nil {
            capabilities.insert(.tangentialPressure)
        }
        return InterpolatedStrokeSample(
            position: WorldPoint(x: 0, y: 0),
            pressure: input.pressure ?? 0,
            timestamp: 0,
            altitude: input.altitude,
            azimuth: input.azimuth,
            roll: input.roll,
            velocity: 0,
            artisticVelocity: 0,
            phase: .moved,
            source: capabilities.isEmpty ? .mouse : .tablet,
            kind: .actual,
            capabilities: capabilities,
            tangentialPressure: input.tangentialPressure
        )
    }

    private static func validate(
        profile: BrushCursorTipProfile,
        component: BrushComponentProgram
    ) throws {
        let expectedShapeCount = profile.secondary == nil ? 1 : 2
        guard component.definition.coverage.shapes.count == expectedShapeCount
        else {
            throw BrushCursorDescriptorError.profileShapeCountMismatch
        }
        guard (profile.secondary == nil)
                == (profile.secondaryCombination == nil)
        else {
            throw BrushCursorDescriptorError.invalidProfile
        }
        try validate(shape: profile.primary)
        if let secondary = profile.secondary {
            try validate(shape: secondary)
        }
    }

    private static func validate(shape: BrushCursorTipShape) throws {
        guard case let .contour(points) = shape else { return }
        guard points.count >= 3,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else {
            throw BrushCursorDescriptorError.invalidProfile
        }
    }

    private static func authoredShapeFrame(
        _ shape: BrushShapeLayerDefinition
    ) -> Affine2D {
        let cosine = cos(shape.rotation) * shape.scale
        let sine = sin(shape.rotation) * shape.scale
        return Affine2D(
            xAxis: SIMD2(cosine, sine),
            yAxis: SIMD2(-sine, cosine),
            translation: shape.offset
        )
    }

    private static func compositeBounds(
        primary: BrushCursorLayerDescriptor,
        secondary: BrushCursorLayerDescriptor?,
        combination: BrushShapeCombinationMode?
    ) throws -> BrushCursorBounds? {
        guard let secondary else { return primary.bounds }
        switch combination {
        case .replace:
            return secondary.bounds
        case .multiply, .minimum:
            let minimum = SIMD2(
                Swift.max(
                    primary.bounds.minimum.x,
                    secondary.bounds.minimum.x
                ),
                Swift.max(
                    primary.bounds.minimum.y,
                    secondary.bounds.minimum.y
                )
            )
            let maximum = SIMD2(
                Swift.min(
                    primary.bounds.maximum.x,
                    secondary.bounds.maximum.x
                ),
                Swift.min(
                    primary.bounds.maximum.y,
                    secondary.bounds.maximum.y
                )
            )
            guard minimum.x < maximum.x, minimum.y < maximum.y else {
                return nil
            }
            return try BrushCursorBounds(minimum: minimum, maximum: maximum)
        case .maximum:
            return try primary.bounds.union(secondary.bounds)
        case nil:
            throw BrushCursorDescriptorError.invalidProfile
        }
    }

    private static func union(
        _ primary: BrushCursorBounds?,
        _ secondary: BrushCursorBounds?
    ) throws -> BrushCursorBounds? {
        switch (primary, secondary) {
        case let (primary?, secondary?):
            return try primary.union(secondary)
        case let (primary?, nil):
            return primary
        case let (nil, secondary?):
            return secondary
        case (nil, nil):
            return nil
        }
    }

    private static func isCircularEllipse(
        _ layer: BrushCursorLayerDescriptor
    ) -> Bool {
        guard case .analyticEllipse = layer.shape else { return false }
        let x = layer.normalizedTipToLogical.xAxis
        let y = layer.normalizedTipToLogical.yAxis
        let xLength = hypot(x.x, x.y)
        let yLength = hypot(y.x, y.y)
        let tolerance = max(xLength, yLength) * 0.000_1
        return abs(xLength - yLength) <= tolerance
            && abs(x.x * y.x + x.y * y.y) <= tolerance
    }
}
