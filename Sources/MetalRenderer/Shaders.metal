#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

constant bool patternDepositionHasSecondaryShape
    [[function_constant(PatternDepositionFunctionConstantSecondaryShape)]];
constant bool patternDepositionHasPrimaryGrain
    [[function_constant(PatternDepositionFunctionConstantPrimaryGrain)]];
constant bool patternDepositionHasSecondaryGrain
    [[function_constant(PatternDepositionFunctionConstantSecondaryGrain)]];
constant uint patternDepositionAccumulationMode
    [[function_constant(PatternDepositionFunctionConstantAccumulation)]];
constant uint patternDepositionEdgeTreatment
    [[function_constant(PatternDepositionFunctionConstantEdgeTreatment)]];

struct PatternVertexOut {
    float4 position [[position]];
};

vertex PatternVertexOut patternBlankVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    PatternVertexOut output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    return output;
}

fragment float4 patternBlankFragment(PatternVertexOut input [[stage_in]]) {
    return float4(242.0 / 255.0, 244.0 / 255.0, 241.0 / 255.0, 1.0);
}

static float patternSRGBChannelToLinear(float encoded) {
    return encoded <= 0.04045
        ? encoded / 12.92
        : pow((encoded + 0.055) / 1.055, 2.4);
}

static float patternLinearChannelToSRGB(float linear) {
    return linear <= 0.0031308
        ? linear * 12.92
        : 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
}

static float4 patternEncodedSRGBToLinearPremultiplied(float4 encoded) {
    const float3 linear = float3(
        patternSRGBChannelToLinear(encoded.r),
        patternSRGBChannelToLinear(encoded.g),
        patternSRGBChannelToLinear(encoded.b)
    );
    return float4(linear * encoded.a, encoded.a);
}

static float4 patternLinearPremultipliedToEncodedSRGB(float4 linear) {
    if (linear.a <= 0.0) {
        return float4(0.0);
    }
    const float3 straight = clamp(linear.rgb / linear.a, 0.0, 1.0);
    return float4(
        patternLinearChannelToSRGB(straight.r),
        patternLinearChannelToSRGB(straight.g),
        patternLinearChannelToSRGB(straight.b),
        linear.a
    );
}

static float4 patternLinearSourceOver(float4 source, float4 destination) {
    return source + destination * (1.0 - source.a);
}

static float4 patternLinearDestinationOut(
    float4 destination,
    float eraseAlpha
) {
    return destination * (1.0 - clamp(eraseAlpha, 0.0, 1.0));
}

static float patternLinearBlendChannel(
    float source,
    float destination,
    uint mode
) {
    switch (mode) {
    case 1:
        return source * destination;
    case 2:
        return source + destination - source * destination;
    default:
        return source;
    }
}

static float4 patternLinearBlend(
    float4 source,
    float4 destination,
    uint mode
) {
    if (mode == 0) {
        return patternLinearSourceOver(source, destination);
    }
    const float3 sourceStraight = source.a > 0.0
        ? source.rgb / source.a
        : float3(0.0);
    const float3 destinationStraight = destination.a > 0.0
        ? destination.rgb / destination.a
        : float3(0.0);
    const float3 blended = float3(
        patternLinearBlendChannel(
            sourceStraight.r,
            destinationStraight.r,
            mode
        ),
        patternLinearBlendChannel(
            sourceStraight.g,
            destinationStraight.g,
            mode
        ),
        patternLinearBlendChannel(
            sourceStraight.b,
            destinationStraight.b,
            mode
        )
    );
    const float3 output =
        sourceStraight * source.a * (1.0 - destination.a)
        + destinationStraight * destination.a * (1.0 - source.a)
        + blended * source.a * destination.a;
    const float outputAlpha = source.a + destination.a * (1.0 - source.a);
    return float4(output, outputAlpha);
}

struct PatternDocumentColorProbeInput {
    float4 source;
    float4 destination;
    uint4 controls;
};

kernel void patternDocumentColorDifferential(
    const device PatternDocumentColorProbeInput* inputs [[buffer(0)]],
    device half4* output [[buffer(1)]],
    uint index [[thread_position_in_grid]]
) {
    const PatternDocumentColorProbeInput input = inputs[index];
    float4 result;
    switch (input.controls.x) {
    case 0:
        result = patternEncodedSRGBToLinearPremultiplied(input.source);
        break;
    case 1:
        result = patternLinearSourceOver(input.source, input.destination);
        break;
    case 2:
        result = input.destination;
        for (uint stamp = 0; stamp < input.controls.y; ++stamp) {
            result = patternLinearSourceOver(input.source, result);
        }
        break;
    case 3:
        result = patternLinearDestinationOut(
            input.destination,
            input.source.a
        );
        break;
    default:
        result = patternLinearBlend(
            input.source,
            input.destination,
            input.controls.x - 4
        );
        break;
    }
    output[index] = half4(result);
}

kernel void patternDepositionABIRoundTrip(
    const device PatternDepositionStampInstance* instances [[buffer(0)]],
    device PatternUInt4* output [[buffer(1)]],
    uint index [[thread_position_in_grid]]
) {
    const PatternDepositionStampInstance instance = instances[index];
    const uint base = index * 7;
    output[base] = as_type<uint4>(instance.tipFrame0);
    output[base + 1] = as_type<uint4>(instance.tipFrame1);
    output[base + 2] = as_type<uint4>(instance.coverageInputs);
    output[base + 3] = instance.identity;
    output[base + 4] = instance.metadata;
    output[base + 5] = as_type<uint4>(instance.reserved0);
    output[base + 6] = uint4(
        instance.metadata.w == PatternDepositionABIVersion ? 1 : 0,
        sizeof(PatternDepositionStampInstance),
        0,
        0
    );
}

struct PatternFullscreenOut {
    float4 position [[position]];
    float2 screenPixel;
};

struct PatternProjectedDepositionOut {
    float4 position [[position]];
    float2 canonical;
    float2 tipLocal;
    float2 primaryGrainCoordinate;
    float2 secondaryGrainCoordinate;
    float radius [[flat]];
    float4 premultipliedColor [[flat]];
    float4 coverageInputs [[flat]];
    float4 clip0 [[flat]];
    float4 clip1 [[flat]];
    float4 clip2 [[flat]];
    float4 clip3 [[flat]];
    uint clipCount [[flat]];
    uint abiVersion [[flat]];
};

static float2 patternDepositionFrameLocal(
    float2 canonical,
    float4 frame0,
    float4 frame1
) {
    const float2 xAxis = frame0.xy;
    const float2 yAxis = frame0.zw;
    const float determinant =
        xAxis.x * yAxis.y - xAxis.y * yAxis.x;
    if (!isfinite(determinant) || abs(determinant) < FLT_EPSILON) {
        return float2(0.0);
    }
    const float2 relative = canonical - frame1.xy;
    return float2(
        (relative.x * yAxis.y - relative.y * yAxis.x) / determinant,
        (xAxis.x * relative.y - xAxis.y * relative.x) / determinant
    );
}

vertex PatternProjectedDepositionOut patternProjectedDepositionVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    const device PatternDepositionStampInstance* instances
        [[buffer(PatternBufferIndexDabInstances)]]
) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    const PatternDepositionStampInstance instance = instances[instanceID];
    const float radius = max(instance.tipFrame1.z, FLT_EPSILON);
    const float2 tipLocal = corners[vertexID] * (1.0 + 1.0 / radius);
    const float2 canonical =
        instance.tipFrame1.xy
        + instance.tipFrame0.xy * tipLocal.x
        + instance.tipFrame0.zw * tipLocal.y;

    PatternProjectedDepositionOut output;
    output.position = float4(
        canonical.x / frame.tileSize.x * 2.0 - 1.0,
        1.0 - canonical.y / frame.tileSize.y * 2.0,
        0.0,
        1.0
    );
    output.canonical = canonical;
    output.tipLocal = tipLocal;
    output.primaryGrainCoordinate = patternDepositionHasPrimaryGrain
        ? patternDepositionFrameLocal(
            canonical,
            instance.primaryGrainFrame0,
            instance.primaryGrainFrame1
        )
        : float2(0.0);
    output.secondaryGrainCoordinate = patternDepositionHasSecondaryGrain
        ? patternDepositionFrameLocal(
            canonical,
            instance.secondaryGrainFrame0,
            instance.secondaryGrainFrame1
        )
        : float2(0.0);
    output.radius = radius;
    output.premultipliedColor = instance.premultipliedColor;
    output.coverageInputs = instance.coverageInputs;
    output.clip0 = float4(
        instance.clip0.normal,
        instance.clip0.offset,
        0.0
    );
    output.clip1 = float4(
        instance.clip1.normal,
        instance.clip1.offset,
        0.0
    );
    output.clip2 = float4(
        instance.clip2.normal,
        instance.clip2.offset,
        0.0
    );
    output.clip3 = float4(
        instance.clip3.normal,
        instance.clip3.offset,
        0.0
    );
    output.clipCount = instance.metadata.x;
    output.abiVersion = instance.metadata.w;
    return output;
}

static bool patternProjectedDepositionInsideClip(
    PatternProjectedDepositionOut input
) {
    if (
        input.clipCount > 0
        && dot(input.clip0.xy, input.tipLocal) < input.clip0.z
    ) {
        return false;
    }
    if (
        input.clipCount > 1
        && dot(input.clip1.xy, input.tipLocal) < input.clip1.z
    ) {
        return false;
    }
    if (
        input.clipCount > 2
        && dot(input.clip2.xy, input.tipLocal) < input.clip2.z
    ) {
        return false;
    }
    if (
        input.clipCount > 3
        && dot(input.clip3.xy, input.tipLocal) < input.clip3.z
    ) {
        return false;
    }
    return true;
}

static float patternDepositionClamp01(float value) {
    return clamp(value, 0.0, 1.0);
}

static float patternDepositionSmoothstep(
    float edge0,
    float edge1,
    float value
) {
    if (edge1 <= edge0) {
        return value >= edge1 ? 1.0 : 0.0;
    }
    const float fraction = patternDepositionClamp01(
        (value - edge0) / (edge1 - edge0)
    );
    return fraction * fraction * (3.0 - 2.0 * fraction);
}

static float patternDepositionCombineShapes(
    float primary,
    float secondary,
    uint mode
) {
    switch (mode) {
    case PatternDepositionShapeCombinationReplace:
        return secondary;
    case PatternDepositionShapeCombinationMultiply:
        return primary * secondary;
    case PatternDepositionShapeCombinationMinimum:
        return min(primary, secondary);
    case PatternDepositionShapeCombinationMaximum:
        return max(primary, secondary);
    default:
        return 0.0;
    }
}

static float patternDepositionCoverage(
    float primaryShape,
    float secondaryShape,
    float primaryGrain,
    float secondaryGrain,
    float signedTipEdgeDistance,
    float4 coverageInputs,
    PatternDepositionMaterialUniforms material,
    bool hasSecondaryShape,
    bool hasPrimaryGrain,
    bool hasSecondaryGrain,
    uint edgeTreatment
) {
    if (
        !isfinite(primaryShape)
        || !isfinite(secondaryShape)
        || !isfinite(primaryGrain)
        || !isfinite(secondaryGrain)
        || !isfinite(signedTipEdgeDistance)
        || any(!isfinite(coverageInputs))
        || any(!isfinite(material.coverageParameters))
        || any(!isfinite(material.edgeParameters))
    ) {
        return 0.0;
    }

    float shape = patternDepositionClamp01(primaryShape);
    if (hasSecondaryShape) {
        shape = patternDepositionCombineShapes(
            shape,
            patternDepositionClamp01(secondaryShape),
            material.options.x
        );
    }

    constexpr float antialiasWidth = 1.0 / 255.0;
    const float hardness = patternDepositionClamp01(coverageInputs.z);
    shape = patternDepositionClamp01(
        (shape - (1.0 - hardness)) / max(hardness, antialiasWidth)
    );
    const float threshold = patternDepositionClamp01(
        material.coverageParameters.z
    );
    if (threshold > 0.0) {
        if (material.options.y != 0) {
            shape *= patternDepositionSmoothstep(
                threshold - antialiasWidth,
                threshold + antialiasWidth,
                shape
            );
        } else {
            shape = shape >= threshold ? shape : 0.0;
        }
    }

    float grain = 1.0;
    if (hasPrimaryGrain) {
        grain *= mix(
            1.0,
            patternDepositionClamp01(primaryGrain),
            patternDepositionClamp01(material.coverageParameters.x)
        );
    }
    if (hasSecondaryGrain) {
        grain *= mix(
            1.0,
            patternDepositionClamp01(secondaryGrain),
            patternDepositionClamp01(material.coverageParameters.y)
        );
    }

    float evaluated = shape * patternDepositionClamp01(grain);
    const float edgeBand = 1.0 - patternDepositionSmoothstep(
        0.0,
        1.0,
        abs(signedTipEdgeDistance)
    );
    const float edgeStrength = patternDepositionClamp01(
        material.edgeParameters.x
    );
    switch (edgeTreatment) {
    case PatternDepositionEdgeNone:
        break;
    case PatternDepositionEdgeDryBreakup: {
        const float rawGrain = patternDepositionClamp01(
            (hasPrimaryGrain ? primaryGrain : 1.0)
                * (hasSecondaryGrain ? secondaryGrain : 1.0)
        );
        const float breakupThreshold = patternDepositionClamp01(
            (1.0 - hardness) * 0.35 + edgeBand * 0.35
        );
        const float dryMask = patternDepositionSmoothstep(
            breakupThreshold,
            min(1.0, breakupThreshold + 0.25),
            rawGrain
        );
        evaluated *= mix(1.0, dryMask, edgeStrength);
        break;
    }
    case PatternDepositionEdgeMarkerOverlap:
        evaluated = patternDepositionClamp01(
            evaluated * (1.0 + 0.25 * edgeStrength * edgeBand)
        );
        break;
    default:
        return 0.0;
    }

    const float base = evaluated
        * patternDepositionClamp01(coverageInputs.x)
        * patternDepositionClamp01(coverageInputs.w);
    return patternDepositionClamp01(base);
}

static float patternDepositionAccumulatedAlpha(
    float current,
    float baseCoverage,
    float flowCoverage,
    uint mode,
    float accumulationLimit
) {
    if (
        !isfinite(current)
        || !isfinite(baseCoverage)
        || !isfinite(flowCoverage)
        || !isfinite(accumulationLimit)
    ) {
        return 0.0;
    }
    const float limit = patternDepositionClamp01(accumulationLimit);
    current = min(limit, patternDepositionClamp01(current));
    const float base = patternDepositionClamp01(baseCoverage);
    const float flow = patternDepositionClamp01(flowCoverage);
    float next;
    switch (mode) {
    case PatternDepositionAccumulationOpaque:
        next = current + (1.0 - current) * base;
        break;
    case PatternDepositionAccumulationFlow:
    case PatternDepositionAccumulationDestinationOut:
        next = current + (1.0 - current) * flow;
        break;
    case PatternDepositionAccumulationUniformGlaze:
        next = max(current, flow);
        break;
    case PatternDepositionAccumulationIntenseGlaze: {
        const float intense = 1.0 - (1.0 - flow) * (1.0 - flow);
        next = current + (1.0 - current) * intense;
        break;
    }
    default:
        return 0.0;
    }
    return min(limit, patternDepositionClamp01(next));
}

static float2 patternDepositionSecondaryShapeLocal(
    float2 tipLocal,
    float4 transform
) {
    const float scale = max(transform.x, FLT_EPSILON);
    const float cosine = cos(transform.y);
    const float sine = sin(transform.y);
    const float2 translated = tipLocal - transform.zw;
    return float2(
        cosine * translated.x + sine * translated.y,
        -sine * translated.x + cosine * translated.y
    ) / scale;
}

static float patternDepositionShapeSample(
    float2 shapeLocal,
    float radius,
    uint kind,
    texture2d<float> texture,
    sampler shapeSampler
) {
    if (kind == PatternDepositionShapeKindHardRound) {
        return patternDepositionClamp01(
            radius + 0.5 - length(shapeLocal * radius)
        );
    }
    if (kind == PatternDepositionShapeKindSoftRound) {
        return patternDepositionClamp01(1.0 - length(shapeLocal));
    }
    if (kind == PatternDepositionShapeKindRectangle) {
        return patternDepositionClamp01(
            radius + 0.5 - max(
                abs(shapeLocal.x * radius),
                abs(shapeLocal.y * radius)
            )
        );
    }
    return texture.sample(
        shapeSampler,
        shapeLocal * 0.5 + 0.5
    ).r;
}

struct PatternDepositionFragmentOutput {
    float4 color [[color(0)]];
    float2 componentCoverage [[color(1)]];
};

fragment PatternDepositionFragmentOutput patternDepositionFragment(
    PatternProjectedDepositionOut input [[stage_in]],
    float2 currentComponentCoverage [[color(1)]],
    constant PatternDepositionMaterialUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    texture2d<float> primaryShapeTexture
        [[texture(PatternTextureIndexDepositionPrimaryShape)]],
    texture2d<float> secondaryShapeTexture
        [[texture(PatternTextureIndexDepositionSecondaryShape)]],
    texture2d<float> primaryGrainTexture
        [[texture(PatternTextureIndexDepositionPrimaryGrain)]],
    texture2d<float> secondaryGrainTexture
        [[texture(PatternTextureIndexDepositionSecondaryGrain)]]
) {
    if (
        input.abiVersion != PatternDepositionABIVersion
        || !patternProjectedDepositionInsideClip(input)
    ) {
        discard_fragment();
    }

    constexpr sampler shapeSampler(
        coord::normalized,
        address::clamp_to_zero,
        filter::linear,
        mip_filter::linear
    );
    constexpr sampler grainSampler(
        coord::normalized,
        address::repeat,
        filter::linear,
        mip_filter::linear
    );

    const float primaryShape = patternDepositionShapeSample(
        input.tipLocal,
        input.radius,
        material.options.z,
        primaryShapeTexture,
        shapeSampler
    );
    const float2 secondaryLocal = patternDepositionHasSecondaryShape
        ? patternDepositionSecondaryShapeLocal(
            input.tipLocal,
            material.secondaryShapeTransform
        )
        : float2(0.0);
    const float secondaryShape = patternDepositionHasSecondaryShape
        ? patternDepositionShapeSample(
            secondaryLocal,
            input.radius,
            material.options.w,
            secondaryShapeTexture,
            shapeSampler
        )
        : 1.0;
    const float primaryGrain = patternDepositionHasPrimaryGrain
        ? primaryGrainTexture.sample(
            grainSampler,
            input.primaryGrainCoordinate
        ).r
        : 1.0;
    const float secondaryGrain = patternDepositionHasSecondaryGrain
        ? secondaryGrainTexture.sample(
            grainSampler,
            input.secondaryGrainCoordinate
        ).r
        : 1.0;
    const float signedTipEdgeDistance = input.radius * (
        material.options.z == PatternDepositionShapeKindHardRound
                || material.options.z == PatternDepositionShapeKindSoftRound
            ? 1.0 - length(input.tipLocal)
            : 1.0 - max(abs(input.tipLocal.x), abs(input.tipLocal.y))
    );
    const float baseCoverage = patternDepositionCoverage(
        primaryShape,
        secondaryShape,
        primaryGrain,
        secondaryGrain,
        signedTipEdgeDistance,
        input.coverageInputs,
        material,
        patternDepositionHasSecondaryShape,
        patternDepositionHasPrimaryGrain,
        patternDepositionHasSecondaryGrain,
        patternDepositionEdgeTreatment
    );
    const float flowCoverage = patternDepositionClamp01(
        baseCoverage * patternDepositionClamp01(input.coverageInputs.y)
    );
    const uint componentOrdinal = min(
        uint(round(material.edgeParameters.y)),
        1u
    );
    const float currentCoverage = patternDepositionClamp01(
        currentComponentCoverage[componentOrdinal]
    );
    const float accumulatedCoverage = patternDepositionAccumulatedAlpha(
        currentCoverage,
        baseCoverage,
        flowCoverage,
        patternDepositionAccumulationMode,
        material.coverageParameters.w
    );
    float depositedCoverage;
    if (
        patternDepositionAccumulationMode
            == PatternDepositionAccumulationUniformGlaze
    ) {
        // The uniform-glaze color pipeline uses max blending, so its source
        // remains the authored component-local cumulative value.
        depositedCoverage = accumulatedCoverage;
    } else {
        // Source-over blending computes d + s(1-d). Solve for the source
        // coverage that reaches this component's authored cumulative result.
        const float remaining = max(1.0 - currentCoverage, FLT_EPSILON);
        depositedCoverage = patternDepositionClamp01(
            (accumulatedCoverage - currentCoverage) / remaining
        );
    }

    float2 nextComponentCoverage = currentComponentCoverage;
    nextComponentCoverage[componentOrdinal] = accumulatedCoverage;
    PatternDepositionFragmentOutput output;
    output.componentCoverage = nextComponentCoverage;
    if (
        patternDepositionAccumulationMode
            == PatternDepositionAccumulationDestinationOut
    ) {
        output.color = float4(0.0, 0.0, 0.0, depositedCoverage);
    } else {
        output.color = input.premultipliedColor * depositedCoverage;
    }
    return output;
}

vertex PatternFullscreenOut patternFullscreenVertex(
    uint vertexID [[vertex_id]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]]
) {
    const float2 clip[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    PatternFullscreenOut output;
    output.position = float4(clip[vertexID], 0.0, 1.0);
    output.screenPixel = float2(
        (clip[vertexID].x + 1.0) * 0.5 * frame.drawableSize.x,
        (1.0 - clip[vertexID].y) * 0.5 * frame.drawableSize.y
    );
    return output;
}

static float patternSignedTriangleEdge(
    float2 start,
    float2 end,
    float2 point
) {
    const float2 edge = end - start;
    const float2 relative = point - start;
    return edge.x * relative.y - edge.y * relative.x;
}

static bool patternInsideAsymmetricTriangle(float2 point) {
    const float2 first = float2(-0.75, -0.60);
    const float2 second = float2(0.85, -0.20);
    const float2 third = float2(-0.10, 0.90);
    return patternSignedTriangleEdge(first, second, point) >= 0.0
        && patternSignedTriangleEdge(second, third, point) >= 0.0
        && patternSignedTriangleEdge(third, first, point) >= 0.0;
}

fragment float4 patternDiagnosticFootprintFragment(
    PatternProjectedDepositionOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]]
) {
    if (
        !patternProjectedDepositionInsideClip(input)
        || !patternInsideAsymmetricTriangle(input.tipLocal)
    ) {
        discard_fragment();
    }

    switch (frame.diagnosticMode) {
    case PatternDiagnosticWireAsymmetricCoverage:
        return float4(0.0, 0.0, 0.0, 1.0);
    case PatternDiagnosticWireCanonicalCoordinates:
        return float4(
            clamp(input.canonical / frame.tileSize, 0.0, 1.0),
            0.0,
            1.0
        );
    case PatternDiagnosticWireBrushLocalCoordinates:
        return float4(
            clamp(input.tipLocal * 0.5 + 0.5, 0.0, 1.0),
            0.0,
            1.0
        );
    default:
        return float4(1.0, 0.0, 1.0, 1.0);
    }
}


static float4 patternSourceOver(float4 source, float4 destination) {
    return source + destination * (1.0 - source.a);
}

static float4 patternLayerBlendValue(
    float4 source,
    float4 backdrop,
    float opacity,
    uint blendMode
) {
    const float4 scaledSource = source * opacity;
    const float sourceAlpha = scaledSource.a;
    const float backdropAlpha = backdrop.a;
    const float3 sourceColor = source.a <= 0.0
        ? float3(0.0) : source.rgb / source.a;
    const float3 backdropColor = backdropAlpha <= 0.0
        ? float3(0.0) : backdrop.rgb / backdropAlpha;
    float3 blendedColor = sourceColor;
    if (blendMode == PatternLayerBlendWireMultiply) {
        blendedColor = sourceColor * backdropColor;
    } else if (blendMode == PatternLayerBlendWireScreen) {
        blendedColor = sourceColor + backdropColor
            - sourceColor * backdropColor;
    }
    const float overlap = sourceAlpha * backdropAlpha;
    const float3 rgb = scaledSource.rgb * (1.0 - backdropAlpha)
        + backdrop.rgb * (1.0 - sourceAlpha)
        + blendedColor * overlap;
    const float alpha = sourceAlpha
        + backdropAlpha * (1.0 - sourceAlpha);
    return float4(rgb, alpha);
}

kernel void patternLayerBlendKernel(
    texture2d<float, access::read> backdrop
        [[texture(PatternTextureIndexLayerBlendBackdrop)]],
    texture2d<float, access::read> source
        [[texture(PatternTextureIndexLayerBlendSource)]],
    texture2d<float, access::write> destination
        [[texture(PatternTextureIndexLayerBlendDestination)]],
    constant PatternCompositeUniforms& uniforms
        [[buffer(PatternBufferIndexLayerBlendUniforms)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destination.get_width()
        || position.y >= destination.get_height()) {
        return;
    }
    destination.write(patternLayerBlendValue(
        source.read(position),
        backdrop.read(position),
        uniforms.parameters.x,
        uint(uniforms.parameters.y)
    ), position);
}

static float4 patternSparseInterchangeOutput(float4 linearPremultiplied);

kernel void patternLayerInterchangePackKernel(
    texture2d<float, access::read> source
        [[texture(PatternTextureIndexLayerBlendSource)]],
    texture2d<float, access::write> destination
        [[texture(PatternTextureIndexLayerBlendDestination)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destination.get_width()
        || position.y >= destination.get_height()) {
        return;
    }
    destination.write(
        patternSparseInterchangeOutput(source.read(position)),
        position
    );
}

static float4 patternCompositeLive(
    float4 settledLive,
    float4 replayLive,
    float4 canonical,
    uint compositeMode,
    float strokeOpacity,
    float accumulationLimit,
    float eraserStrength
) {
    float4 live = patternSourceOver(replayLive, settledLive);
    const float alpha = clamp(live.a, 0.0, 1.0);
    const float limitedAlpha = min(
        alpha,
        clamp(accumulationLimit, 0.0, 1.0)
    );
    live = alpha <= 0.000001
        ? float4(0.0)
        : float4(max(live.rgb, float3(0.0)), alpha)
            * (limitedAlpha / alpha);
    if (compositeMode == PatternCompositeWireErase) {
        return canonical * (
            1.0 - live.a * clamp(eraserStrength, 0.0, 1.0)
        );
    }
    live *= clamp(strokeOpacity, 0.0, 1.0);
    return patternSourceOver(live, canonical);
}



static bool patternRadialOrbitIntersectsCanvas(
    float2 logicalPoint,
    constant PatternRadialFrameUniforms& radial
);



struct PatternRadialMapping {
    float2 logicalPixel;
    float radius;
    float relativeAngle;
    bool valid;
};

static PatternRadialMapping patternRadialMapping(
    float2 world,
    constant PatternGridFrameUniforms& frame,
    constant PatternRadialFrameUniforms& radial
) {
    if (
        world.x < 0.0
        || world.y < 0.0
        || world.x >= radial.canvasSize.x
        || world.y >= radial.canvasSize.y
    ) {
        return {float2(0.0), 0.0, 0.0, false};
    }
    if (frame.tilingKind == PatternTilingWirePlainCanvas) {
        return {world, 0.0, 0.0, true};
    }

    const float2 relative = world - radial.center;
    const float radius = length(relative);
    if (radius == 0.0) {
        return {float2(0.0), 0.0, 0.0, true};
    }
    const float fullTurn = 2.0 * M_PI_F;
    float angle = atan2(relative.y, relative.x)
        - radial.referenceAngle;
    angle = fmod(angle, fullTurn);
    if (angle < 0.0) {
        angle += fullTurn;
    }
    uint sector = min(
        uint(floor(angle / radial.sectorAngle)),
        radial.displayedSectorCount - 1
    );
    float localAngle = angle - float(sector) * radial.sectorAngle;
    if (radial.dihedral != 0 && (sector & 1u) != 0) {
        localAngle = radial.sectorAngle - localAngle;
    }
    if (localAngle == radial.sectorAngle) {
        localAngle = nextafter(radial.sectorAngle, 0.0);
    }
    return {
        radius * float2(cos(localAngle), sin(localAngle)),
        radius,
        angle,
        true
    };
}


static bool patternRadialOrbitIntersectsCanvas(
    float2 logicalPoint,
    constant PatternRadialFrameUniforms& radial
) {
    if (radial.displayedSectorCount == 1) {
        return (
            logicalPoint.x >= 0.0
            && logicalPoint.y >= 0.0
            && logicalPoint.x < radial.canvasSize.x
            && logicalPoint.y < radial.canvasSize.y
        );
    }
    const uint rays = radial.dihedral != 0
        ? radial.displayedSectorCount / 2
        : radial.displayedSectorCount;
    const float step = 2.0 * M_PI_F / float(rays);
    const float radius = length(logicalPoint);
    const float localAngle = atan2(logicalPoint.y, logicalPoint.x);
    for (uint index = 0; index < rays; ++index) {
        const float angle = radial.referenceAngle
            + localAngle + float(index) * step;
        const float2 world = radial.center
            + radius * float2(cos(angle), sin(angle));
        if (
            world.x >= 0.0 && world.y >= 0.0
            && world.x < radial.canvasSize.x
            && world.y < radial.canvasSize.y
        ) {
            return true;
        }
        if (radial.dihedral != 0) {
            const float reflectedAngle = radial.referenceAngle
                - localAngle + float(index) * step;
            const float2 reflectedWorld = radial.center
                + radius * float2(
                    cos(reflectedAngle),
                    sin(reflectedAngle)
                );
            if (
                reflectedWorld.x >= 0.0 && reflectedWorld.y >= 0.0
                && reflectedWorld.x < radial.canvasSize.x
                && reflectedWorld.y < radial.canvasSize.y
            ) {
                return true;
            }
        }
    }
    return false;
}


// Current document-paint sampling path used by display and stable collection.
vertex PatternFullscreenOut patternSparseSamplingVertex(
    uint vertexID [[vertex_id]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]]
) {
    const float2 clip[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };
    PatternFullscreenOut output;
    output.position = float4(clip[vertexID], 0.0, 1.0);
    output.screenPixel = float2(
        (clip[vertexID].x + 1.0) * 0.5 * float(sparse.outputSize.x),
        (1.0 - clip[vertexID].y) * 0.5 * float(sparse.outputSize.y)
    );
    return output;
}

struct PatternSparseResolvedAddress {
    int globalSlot;
    uint2 localTexel;
    bool valid;
};

static int patternSparseFloorDivide(int value, int divisor) {
    const int quotient = value / divisor;
    const int remainder = value % divisor;
    return remainder < 0 ? quotient - 1 : quotient;
}

static int patternSparsePositiveRemainder(int value, int modulus) {
    const int remainder = value % modulus;
    return remainder < 0 ? remainder + modulus : remainder;
}

static int2 patternSparseUnpackBound(uint packed) {
    return int2(int(packed & 0xffffu), int((packed >> 16) & 0xffffu));
}

static bool patternSparseDescriptorIndex(
    uint role,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    thread uint& result
) {
    for (uint index = 0; index < sparse.descriptorCount; ++index) {
        const PatternSparsePageTableDescriptor descriptor = descriptors[index];
        if (descriptor.layerIndex == 0 && descriptor.role == role) {
            result = index;
            return true;
        }
    }
    return false;
}

static PatternSparseResolvedAddress patternSparseResolveAddress(
    int2 logicalPixel,
    uint role,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries
) {
    int2 addressed = logicalPixel;
    if ((sparse.addressingFlags & PatternSparseAddressingPeriodic) != 0) {
        addressed = int2(
            patternSparsePositiveRemainder(addressed.x, int(sparse.period.x)),
            patternSparsePositiveRemainder(addressed.y, int(sparse.period.y))
        );
    }
    uint descriptorIndex;
    if (!patternSparseDescriptorIndex(
        role, sparse, descriptors, descriptorIndex
    )) {
        return {-1, uint2(0), false};
    }
    const PatternSparsePageTableDescriptor descriptor =
        descriptors[descriptorIndex];
    const int2 page = int2(
        patternSparseFloorDivide(addressed.x, 256),
        patternSparseFloorDivide(addressed.y, 256)
    );
    const int2 relative = page - descriptor.tableOrigin;
    if (relative.x < 0 || relative.y < 0
        || relative.x >= int(descriptor.tableSize.x)
        || relative.y >= int(descriptor.tableSize.y)) {
        return {-1, uint2(0), false};
    }
    const uint localEntry = uint(relative.y) * descriptor.tableSize.x
        + uint(relative.x);
    if (localEntry >= descriptor.entryCount) {
        return {-1, uint2(0), false};
    }
    const PatternSparseTilePageEntry entry =
        entries[descriptor.entryOffset + localEntry];
    if (entry.globalBindingSlot < 0
        || (entry.flags & PatternSparsePageEntryKnownClear) != 0) {
        return {-1, uint2(0), false};
    }
    const int2 local = addressed - entry.logicalOrigin;
    const int2 localMinimum = patternSparseUnpackBound(
        entry.packedLocalMinimum
    );
    const int2 localMaximum = patternSparseUnpackBound(
        entry.packedLocalMaximum
    );
    if (local.x < localMinimum.x || local.y < localMinimum.y
        || local.x >= localMaximum.x || local.y >= localMaximum.y) {
        return {-1, uint2(0), false};
    }
    return {entry.globalBindingSlot, uint2(local), true};
}

static float4 patternSparseComposeNeighbor(
    float4 canonical,
    float4 authoritative,
    float4 prediction,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternCompositeUniforms& material
) {
    if (sparse.liveVisible == 0) {
        return canonical;
    }
    return float4(half4(patternCompositeLive(
        authoritative,
        prediction,
        canonical,
        sparse.compositeMode,
        material.parameters.x,
        material.parameters.y,
        material.parameters.z
    )));
}

static float4 patternSparseBilinear(
    float4 value00,
    float4 value10,
    float4 value01,
    float4 value11,
    float2 fraction
) {
    return mix(
        mix(value00, value10, fraction.x),
        mix(value01, value11, fraction.x),
        fraction.y
    );
}

static float4 patternSparseTier2Read(
    PatternSparseResolvedAddress address,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparseTextureArguments& arguments
) {
    if (!address.valid || address.globalSlot >= int(sparse.bindingCount)) {
        return float4(0.0);
    }
    return arguments.textures[uint(address.globalSlot)].read(
        address.localTexel
    );
}

static float4 patternSparseFallbackRead(
    PatternSparseResolvedAddress address,
    constant PatternSparseSamplingUniforms& sparse,
    constant int* remap,
    array<texture2d<float>, 16> textures
) {
    if (!address.valid || address.globalSlot >= int(sparse.bindingCount)) {
        return float4(0.0);
    }
    const int localSlot = remap[address.globalSlot];
    if (localSlot < 0 || localSlot >= 16) {
        return float4(0.0);
    }
    return textures[uint(localSlot)].read(address.localTexel);
}

static float4 patternSparseTier2Neighbor(
    int2 logicalPixel,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternCompositeUniforms& material,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant PatternSparseTextureArguments& arguments
) {
    return patternSparseComposeNeighbor(
        patternSparseTier2Read(patternSparseResolveAddress(
            logicalPixel, PatternSparseRoleCanonical, sparse,
            descriptors, entries
        ), sparse, arguments),
        patternSparseTier2Read(patternSparseResolveAddress(
            logicalPixel, PatternSparseRoleAuthoritative, sparse,
            descriptors, entries
        ), sparse, arguments),
        patternSparseTier2Read(patternSparseResolveAddress(
            logicalPixel, PatternSparseRolePrediction, sparse,
            descriptors, entries
        ), sparse, arguments),
        sparse,
        material
    );
}

static float4 patternSparseFallbackNeighbor(
    int2 logicalPixel,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternCompositeUniforms& material,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant int* remap,
    array<texture2d<float>, 16> textures
) {
    return patternSparseComposeNeighbor(
        patternSparseFallbackRead(patternSparseResolveAddress(
            logicalPixel, PatternSparseRoleCanonical, sparse,
            descriptors, entries
        ), sparse, remap, textures),
        patternSparseFallbackRead(patternSparseResolveAddress(
            logicalPixel, PatternSparseRoleAuthoritative, sparse,
            descriptors, entries
        ), sparse, remap, textures),
        patternSparseFallbackRead(patternSparseResolveAddress(
            logicalPixel, PatternSparseRolePrediction, sparse,
            descriptors, entries
        ), sparse, remap, textures),
        sparse,
        material
    );
}

static float4 patternSparseSamplingTier2ValueAtSamplePosition(
    float2 samplePosition,
    constant PatternCompositeUniforms& material,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant PatternSparseTextureArguments& arguments
) {
    const int2 lower = int2(floor(samplePosition));
    const float2 fraction = fract(samplePosition);
    return patternSparseBilinear(
        patternSparseTier2Neighbor(
            lower, sparse, material, descriptors, entries, arguments
        ),
        patternSparseTier2Neighbor(
            lower + int2(1, 0), sparse, material,
            descriptors, entries, arguments
        ),
        patternSparseTier2Neighbor(
            lower + int2(0, 1), sparse, material,
            descriptors, entries, arguments
        ),
        patternSparseTier2Neighbor(
            lower + int2(1, 1), sparse, material,
            descriptors, entries, arguments
        ),
        fraction
    );
}

static float4 patternSparseSamplingTier2ValueAtPoint(
    float2 point,
    constant PatternCompositeUniforms& material,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant PatternSparseTextureArguments& arguments
) {
    return patternSparseSamplingTier2ValueAtSamplePosition(
        point - 0.5, material, sparse, descriptors, entries, arguments
    );
}

static float4 patternSparseSamplingFallbackValueAtSamplePosition(
    float2 samplePosition,
    constant PatternCompositeUniforms& material,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant int* remap,
    array<texture2d<float>, 16> textures
) {
    const int2 lower = int2(floor(samplePosition));
    const float2 fraction = fract(samplePosition);
    return patternSparseBilinear(
        patternSparseFallbackNeighbor(
            lower, sparse, material, descriptors, entries, remap, textures
        ),
        patternSparseFallbackNeighbor(
            lower + int2(1, 0), sparse, material,
            descriptors, entries, remap, textures
        ),
        patternSparseFallbackNeighbor(
            lower + int2(0, 1), sparse, material,
            descriptors, entries, remap, textures
        ),
        patternSparseFallbackNeighbor(
            lower + int2(1, 1), sparse, material,
            descriptors, entries, remap, textures
        ),
        fraction
    );
}

static float4 patternSparseSamplingFallbackValueAtPoint(
    float2 point,
    constant PatternCompositeUniforms& material,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant int* remap,
    array<texture2d<float>, 16> textures
) {
    return patternSparseSamplingFallbackValueAtSamplePosition(
        point - 0.5, material, sparse, descriptors, entries, remap, textures
    );
}

static float4 patternSparseSamplingTier2Value(
    PatternFullscreenOut input,
    constant PatternCompositeUniforms& material,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant PatternSparseTextureArguments& arguments
) {
    const float2 point = sparse.sourceOrigin + input.screenPixel
        * sparse.sourceStep;
    return patternSparseSamplingTier2ValueAtPoint(
        point, material, sparse, descriptors, entries, arguments
    );
}

static float4 patternSparseSamplingFallbackValue(
    PatternFullscreenOut input,
    constant PatternCompositeUniforms& material,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant int* remap,
    array<texture2d<float>, 16> textures
) {
    const float2 point = sparse.sourceOrigin + input.screenPixel
        * sparse.sourceStep;
    return patternSparseSamplingFallbackValueAtPoint(
        point, material, sparse, descriptors, entries, remap, textures
    );
}

// The CPU reachability authority enumerates the explicitly written IEEE Float
// expressions below. Prevent cross-statement contraction/reassociation from
// inventing an unbounded fold-to-bilinear address outside that finite set.
#pragma clang fp reassociate(off)
#pragma clang fp contract(off)
static int patternPeriodicFoldCellIndex(
    float coordinate,
    float extent,
    float phase
) {
    int result = int(floor(metal::precise::divide(
        coordinate - phase, extent
    )));
    const float origin = float(result) * extent + phase;
    const float boundary = origin + extent;
    if (coordinate < origin) {
        result -= 1;
    } else if (coordinate >= boundary) {
        result += 1;
    }
    return result;
}

static float patternPeriodicFoldPositiveModulo(float value, float extent) {
    const float normalized = abs(value) < FLT_MIN ? 0.0 : value;
    const float remainder = metal::precise::fmod(normalized, extent);
    if (remainder == 0.0 || abs(remainder) < FLT_MIN) {
        return 0.0;
    }
    if (remainder < 0.0) {
        return min(remainder + extent, nextafter(extent, 0.0));
    }
    return remainder;
}

static float patternPeriodicPhaseOffset(
    int index,
    constant PatternPeriodicDisplayFoldUniforms& fold
) {
    if (fold.phaseCount == 0) {
        return 0.0;
    }
    const int count = int(fold.phaseCount);
    const int remainder = index % count;
    const uint slot = uint(remainder >= 0 ? remainder : remainder + count);
    const float fraction = fold.phaseFractions[slot];
    const float extent = fold.phaseOffsetAxis == 0
        ? fold.repeatSize.x : fold.repeatSize.y;
    return fraction * extent;
}

static float2 patternPeriodicDisplayFold(
    float2 world,
    constant PatternPeriodicDisplayFoldUniforms& fold
) {
    if (fold.foldMode == 1) {
        const float2 lattice = fold.worldToLatticeXAxis * world.x
            + fold.worldToLatticeYAxis * world.y
            + fold.worldToLatticeTranslation;
        return float2(
            patternPeriodicFoldPositiveModulo(lattice.x, 1.0)
                * fold.canonicalSize.x,
            patternPeriodicFoldPositiveModulo(lattice.y, 1.0)
                * fold.canonicalSize.y
        );
    }

    int column;
    int row;
    float2 phasedWorld = world;
    if (fold.phaseCount == 0) {
        column = patternPeriodicFoldCellIndex(
            world.x, fold.repeatSize.x, 0.0
        );
        row = patternPeriodicFoldCellIndex(
            world.y, fold.repeatSize.y, 0.0
        );
    } else if (fold.phaseIndexAxis == 0) {
        column = patternPeriodicFoldCellIndex(
            world.x, fold.repeatSize.x, 0.0
        );
        const float offset = patternPeriodicPhaseOffset(column, fold);
        row = patternPeriodicFoldCellIndex(
            world.y, fold.repeatSize.y, offset
        );
        if (fold.phaseOffsetAxis == 0) {
            phasedWorld.x -= offset;
        } else {
            phasedWorld.y -= offset;
        }
    } else {
        row = patternPeriodicFoldCellIndex(
            world.y, fold.repeatSize.y, 0.0
        );
        const float offset = patternPeriodicPhaseOffset(row, fold);
        column = patternPeriodicFoldCellIndex(
            world.x, fold.repeatSize.x, offset
        );
        if (fold.phaseOffsetAxis == 0) {
            phasedWorld.x -= offset;
        } else {
            phasedWorld.y -= offset;
        }
    }

    const float scaledX = patternPeriodicFoldPositiveModulo(
        phasedWorld.x, fold.repeatSize.x
    ) * fold.canonicalSize.x;
    const float scaledY = patternPeriodicFoldPositiveModulo(
        phasedWorld.y, fold.repeatSize.y
    ) * fold.canonicalSize.y;
    float2 local = float2(
        metal::precise::divide(scaledX, fold.repeatSize.x),
        metal::precise::divide(scaledY, fold.repeatSize.y)
    );
    if ((fold.reflectionFlags & 1u) != 0u && (column % 2) != 0) {
        local.x = patternPeriodicFoldPositiveModulo(
            fold.canonicalSize.x - local.x,
            fold.canonicalSize.x
        );
    }
    if ((fold.reflectionFlags & 2u) != 0u && (row % 2) != 0) {
        local.y = patternPeriodicFoldPositiveModulo(
            fold.canonicalSize.y - local.y,
            fold.canonicalSize.y
        );
    }
    return local;
}

static float4 patternSparsePeriodicSamplingTier2Value(
    PatternFullscreenOut input,
    constant PatternPeriodicDisplayFoldUniforms& fold,
    constant PatternCompositeUniforms& material,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant PatternSparseTextureArguments& arguments
) {
    const float2 rootPixel = input.screenPixel + float2(sparse.reserved);
    const float2 world = sparse.sourceOrigin + rootPixel * sparse.sourceStep;
    const float2 samplePosition = patternPeriodicDisplayFold(world, fold)
        - 0.5;
    return patternSparseSamplingTier2ValueAtSamplePosition(
        samplePosition,
        material, sparse, descriptors, entries, arguments
    );
}

static float4 patternSparsePeriodicSamplingFallbackValue(
    PatternFullscreenOut input,
    constant PatternPeriodicDisplayFoldUniforms& fold,
    constant PatternCompositeUniforms& material,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant int* remap,
    array<texture2d<float>, 16> textures
) {
    const float2 rootPixel = input.screenPixel + float2(sparse.reserved);
    const float2 world = sparse.sourceOrigin + rootPixel * sparse.sourceStep;
    const float2 samplePosition = patternPeriodicDisplayFold(world, fold)
        - 0.5;
    return patternSparseSamplingFallbackValueAtSamplePosition(
        samplePosition,
        material, sparse, descriptors, entries, remap, textures
    );
}
#pragma clang fp contract(on)
#pragma clang fp reassociate(on)

static PatternRadialMapping patternSparseRadialMapping(
    PatternFullscreenOut input,
    constant PatternGridFrameUniforms& frame,
    constant PatternRadialFrameUniforms& radial
) {
    const float2 screenCenter = frame.drawableSize * 0.5;
    const float2 world = (input.screenPixel - screenCenter) / frame.zoom
        + frame.worldCenter;
    return patternRadialMapping(world, frame, radial);
}

static float4 patternSparseRadialDisplayOverlay(
    float4 color,
    PatternFullscreenOut input,
    constant PatternGridFrameUniforms& frame,
    constant PatternRadialFrameUniforms& radial
) {
    const PatternRadialMapping mapping = patternSparseRadialMapping(
        input, frame, radial
    );
    if (!mapping.valid) {
        return color;
    }
    if (
        frame.showGridLines != 0
        && frame.tilingKind != PatternTilingWirePlainCanvas
    ) {
        const float sectorPhase = fmod(
            mapping.relativeAngle,
            radial.sectorAngle
        );
        const float axisAngle = min(
            sectorPhase,
            radial.sectorAngle - sectorPhase
        );
        const float axisDistance =
            mapping.radius * abs(sin(axisAngle)) * frame.zoom;
        const float centerDistance = abs(
            mapping.radius * frame.zoom - 4.0
        );
        const float coverage = 1.0 - smoothstep(
            frame.gridLineWidth,
            frame.gridLineWidth + 1.0,
            min(axisDistance, centerDistance)
        );
        const float alpha = 0.24 * coverage;
        color = patternSourceOver(
            float4(float3(0.18, 0.20, 0.19) * alpha, alpha),
            color
        );
    }
    if (frame.showCanvasBoundary != 0) {
        const float2 screenCenter = frame.drawableSize * 0.5;
        const float2 world =
            (input.screenPixel - screenCenter) / frame.zoom
            + frame.worldCenter;
        const float edgeDistance = min(
            min(world.x, radial.canvasSize.x - world.x),
            min(world.y, radial.canvasSize.y - world.y)
        ) * frame.zoom;
        const float coverage = 1.0 - smoothstep(
            0.5, 1.5, edgeDistance
        );
        const float alpha = 0.36 * coverage;
        color = patternSourceOver(
            float4(float3(0.16, 0.18, 0.17) * alpha, alpha),
            color
        );
    }
    return color;
}

fragment float4 patternLayerCompositeDisplayFragment(
    PatternFullscreenOut input [[stage_in]],
    texture2d<float> source
        [[texture(PatternTextureIndexLayerBlendSource)]]
) {
    return source.read(uint2(input.screenPixel));
}

fragment float4 patternLayerCompositeRadialDisplayFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternRadialFrameUniforms& radial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    texture2d<float> source
        [[texture(PatternTextureIndexLayerBlendSource)]]
) {
    return patternSparseRadialDisplayOverlay(
        source.read(uint2(input.screenPixel)),
        input,
        frame,
        radial
    );
}

static float4 patternSparseRadialSamplingTier2Value(
    PatternFullscreenOut input,
    constant PatternGridFrameUniforms& frame,
    constant PatternRadialFrameUniforms& radial,
    constant PatternCompositeUniforms& material,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant PatternSparseTextureArguments& arguments
) {
    const PatternRadialMapping mapping = patternSparseRadialMapping(
        input, frame, radial
    );
    if (!mapping.valid) {
        return float4(0.0);
    }
    return patternSparseSamplingTier2ValueAtPoint(
        mapping.logicalPixel,
        material,
        sparse,
        descriptors,
        entries,
        arguments
    );
}

static float4 patternSparseRadialSamplingFallbackValue(
    PatternFullscreenOut input,
    constant PatternGridFrameUniforms& frame,
    constant PatternRadialFrameUniforms& radial,
    constant PatternCompositeUniforms& material,
    constant PatternSparseSamplingUniforms& sparse,
    constant PatternSparsePageTableDescriptor* descriptors,
    constant PatternSparseTilePageEntry* entries,
    constant int* remap,
    array<texture2d<float>, 16> textures
) {
    const PatternRadialMapping mapping = patternSparseRadialMapping(
        input, frame, radial
    );
    if (!mapping.valid) {
        return float4(0.0);
    }
    return patternSparseSamplingFallbackValueAtPoint(
        mapping.logicalPixel,
        material,
        sparse,
        descriptors,
        entries,
        remap,
        textures
    );
}

fragment float4 patternSparseSamplingTier2Fragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant PatternSparseTextureArguments& arguments
        [[buffer(PatternBufferIndexSparseTextureArguments)]]
) {
    return patternSparseSamplingTier2Value(
        input, material, sparse, descriptors, entries, arguments
    );
}

fragment float4 patternSparseSamplingFallbackFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant int* remap [[buffer(PatternBufferIndexSparseBindingRemap)]],
    array<texture2d<float>, 16> textures
        [[texture(PatternTextureIndexSparseFallbackBase)]]
) {
    return patternSparseSamplingFallbackValue(
        input, material, sparse, descriptors, entries, remap, textures
    );
}

fragment float4 patternSparsePeriodicSamplingTier2Fragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternPeriodicDisplayFoldUniforms& fold
        [[buffer(PatternBufferIndexPeriodicDisplayFold)]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant PatternSparseTextureArguments& arguments
        [[buffer(PatternBufferIndexSparseTextureArguments)]]
) {
    return patternSparsePeriodicSamplingTier2Value(
        input, fold, material, sparse, descriptors, entries, arguments
    );
}

fragment float4 patternSparsePeriodicSamplingFallbackFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternPeriodicDisplayFoldUniforms& fold
        [[buffer(PatternBufferIndexPeriodicDisplayFold)]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant int* remap [[buffer(PatternBufferIndexSparseBindingRemap)]],
    array<texture2d<float>, 16> textures
        [[texture(PatternTextureIndexSparseFallbackBase)]]
) {
    return patternSparsePeriodicSamplingFallbackValue(
        input, fold, material, sparse, descriptors, entries, remap, textures
    );
}

static float4 patternSparseInterchangeOutput(float4 linearPremultiplied) {
    const float4 encodedStraight =
        patternLinearPremultipliedToEncodedSRGB(linearPremultiplied);
    return float4(
        encodedStraight.rgb * encodedStraight.a,
        encodedStraight.a
    );
}

fragment float4 patternSparseSamplingInterchangeTier2Fragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant PatternSparseTextureArguments& arguments
        [[buffer(PatternBufferIndexSparseTextureArguments)]]
) {
    return patternSparseInterchangeOutput(patternSparseSamplingTier2Value(
        input, material, sparse, descriptors, entries, arguments
    ));
}

fragment float4 patternSparseSamplingInterchangeFallbackFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant int* remap [[buffer(PatternBufferIndexSparseBindingRemap)]],
    array<texture2d<float>, 16> textures
        [[texture(PatternTextureIndexSparseFallbackBase)]]
) {
    return patternSparseInterchangeOutput(patternSparseSamplingFallbackValue(
        input, material, sparse, descriptors, entries, remap, textures
    ));
}

fragment float4 patternSparsePeriodicSamplingInterchangeTier2Fragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternPeriodicDisplayFoldUniforms& fold
        [[buffer(PatternBufferIndexPeriodicDisplayFold)]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant PatternSparseTextureArguments& arguments
        [[buffer(PatternBufferIndexSparseTextureArguments)]]
) {
    return patternSparseInterchangeOutput(
        patternSparsePeriodicSamplingTier2Value(
            input, fold, material, sparse, descriptors, entries, arguments
        )
    );
}

fragment float4 patternSparsePeriodicSamplingInterchangeFallbackFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternPeriodicDisplayFoldUniforms& fold
        [[buffer(PatternBufferIndexPeriodicDisplayFold)]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant int* remap [[buffer(PatternBufferIndexSparseBindingRemap)]],
    array<texture2d<float>, 16> textures
        [[texture(PatternTextureIndexSparseFallbackBase)]]
) {
    return patternSparseInterchangeOutput(
        patternSparsePeriodicSamplingFallbackValue(
            input, fold, material, sparse, descriptors, entries,
            remap, textures
        )
    );
}

fragment float4 patternSparseRadialSamplingWorkingTier2Fragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternRadialFrameUniforms& radial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant PatternSparseTextureArguments& arguments
        [[buffer(PatternBufferIndexSparseTextureArguments)]]
) {
    return patternSparseRadialSamplingTier2Value(
        input, frame, radial, material, sparse,
        descriptors, entries, arguments
    );
}

fragment float4 patternSparseRadialSamplingWorkingFallbackFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternRadialFrameUniforms& radial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant int* remap [[buffer(PatternBufferIndexSparseBindingRemap)]],
    array<texture2d<float>, 16> textures
        [[texture(PatternTextureIndexSparseFallbackBase)]]
) {
    return patternSparseRadialSamplingFallbackValue(
        input, frame, radial, material, sparse,
        descriptors, entries, remap, textures
    );
}

fragment float4 patternSparseRadialSamplingDisplayTier2Fragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternRadialFrameUniforms& radial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant PatternSparseTextureArguments& arguments
        [[buffer(PatternBufferIndexSparseTextureArguments)]]
) {
    return patternSparseRadialDisplayOverlay(
        patternSparseRadialSamplingTier2Value(
            input, frame, radial, material, sparse,
            descriptors, entries, arguments
        ),
        input, frame, radial
    );
}

fragment float4 patternSparseRadialSamplingDisplayFallbackFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternRadialFrameUniforms& radial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant int* remap [[buffer(PatternBufferIndexSparseBindingRemap)]],
    array<texture2d<float>, 16> textures
        [[texture(PatternTextureIndexSparseFallbackBase)]]
) {
    return patternSparseRadialDisplayOverlay(
        patternSparseRadialSamplingFallbackValue(
            input, frame, radial, material, sparse,
            descriptors, entries, remap, textures
        ),
        input, frame, radial
    );
}

fragment float4 patternSparseRadialSamplingInterchangeTier2Fragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternRadialFrameUniforms& radial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant PatternSparseTextureArguments& arguments
        [[buffer(PatternBufferIndexSparseTextureArguments)]]
) {
    return patternSparseInterchangeOutput(
        patternSparseRadialSamplingTier2Value(
            input, frame, radial, material, sparse,
            descriptors, entries, arguments
        )
    );
}

fragment float4 patternSparseRadialSamplingInterchangeFallbackFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternCompositeUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternRadialFrameUniforms& radial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    constant PatternSparseSamplingUniforms& sparse
        [[buffer(PatternBufferIndexSparseSamplingUniforms)]],
    constant PatternSparsePageTableDescriptor* descriptors
        [[buffer(PatternBufferIndexSparsePageTableDescriptors)]],
    constant PatternSparseTilePageEntry* entries
        [[buffer(PatternBufferIndexSparsePageEntries)]],
    constant int* remap [[buffer(PatternBufferIndexSparseBindingRemap)]],
    array<texture2d<float>, 16> textures
        [[texture(PatternTextureIndexSparseFallbackBase)]]
) {
    return patternSparseInterchangeOutput(
        patternSparseRadialSamplingFallbackValue(
            input, frame, radial, material, sparse,
            descriptors, entries, remap, textures
        )
    );
}

static bool patternDocumentPaintIsValidPremultiplied(float4 value) {
    return all(isfinite(value))
        && value.a >= 0.0
        && value.a <= 1.0
        && all(value.rgb >= float3(0.0))
        && all(value.rgb <= float3(value.a + 0.00001));
}

static void patternDocumentPaintStoreAndReduce(
    float4 value,
    bool inputWasValid,
    uint2 texel,
    uint2 logicalExtent,
    texture2d<float, access::write> destination,
    device atomic_uint* reduction
) {
    const bool inLogicalBounds = all(texel < logicalExtent);
    if (!inLogicalBounds) {
        destination.write(float4(0.0), texel);
        return;
    }

    const bool outputWasValid = patternDocumentPaintIsValidPremultiplied(value);
    const half4 stored = half4(value);
    const float4 storedValue = float4(stored);
    destination.write(storedValue, texel);
    if (
        !inputWasValid
        || !outputWasValid
        || !patternDocumentPaintIsValidPremultiplied(storedValue)
    ) {
        atomic_store_explicit(&reduction[1], 1u, memory_order_relaxed);
        return;
    }
    atomic_fetch_max_explicit(
        &reduction[0],
        as_type<uint>(storedValue.a),
        memory_order_relaxed
    );
}

kernel void patternDocumentPaintStrokeMutation(
    texture2d<float, access::read> base
        [[texture(PatternTextureIndexDocumentPaintBase)]],
    texture2d<float, access::read> authoritative
        [[texture(PatternTextureIndexDocumentPaintAuthoritative)]],
    texture2d<float, access::read> prediction
        [[texture(PatternTextureIndexDocumentPaintPrediction)]],
    texture2d<float, access::write> destination
        [[texture(PatternTextureIndexDocumentPaintDestination)]],
    constant PatternDocumentPaintMutationUniforms& mutation
        [[buffer(PatternBufferIndexDocumentPaintMutationUniforms)]],
    device atomic_uint* reduction
        [[buffer(PatternBufferIndexDocumentPaintMutationReduction)]],
    uint2 texel [[thread_position_in_grid]]
) {
    if (any(texel >= uint2(destination.get_width(), destination.get_height()))) {
        return;
    }
    if (any(texel >= mutation.logicalExtent)) {
        destination.write(float4(0.0), texel);
        return;
    }
    const float4 baseValue =
        (mutation.flags & PatternDocumentPaintFlagBaseKnownClear) != 0
        ? float4(0.0)
        : base.read(texel);
    const float4 authoritativeValue =
        (mutation.flags & PatternDocumentPaintFlagAuthoritativeKnownClear) != 0
        ? float4(0.0)
        : authoritative.read(texel);
    const float4 predictionValue =
        (mutation.flags & PatternDocumentPaintFlagPredictionKnownClear) != 0
        ? float4(0.0)
        : prediction.read(texel);
    const bool inputWasValid =
        patternDocumentPaintIsValidPremultiplied(baseValue)
        && patternDocumentPaintIsValidPremultiplied(authoritativeValue)
        && patternDocumentPaintIsValidPremultiplied(predictionValue);
    const float4 result = patternCompositeLive(
        authoritativeValue,
        predictionValue,
        baseValue,
        mutation.compositeMode,
        mutation.parameters.x,
        mutation.parameters.y,
        mutation.parameters.z
    );
    patternDocumentPaintStoreAndReduce(
        result,
        inputWasValid,
        texel,
        mutation.logicalExtent,
        destination,
        reduction
    );
}

kernel void patternCompositeTileAlphaReduction(
    texture2d<float, access::read> source
        [[texture(PatternTextureIndexDocumentPaintBase)]],
    constant PatternDocumentPaintMutationUniforms& mutation
        [[buffer(PatternBufferIndexDocumentPaintMutationUniforms)]],
    device atomic_uint* reduction
        [[buffer(PatternBufferIndexDocumentPaintMutationReduction)]],
    uint2 texel [[thread_position_in_grid]]
) {
    if (any(texel >= uint2(source.get_width(), source.get_height()))
        || any(texel >= mutation.logicalExtent)) {
        return;
    }
    const float4 value = source.read(texel);
    if (!patternDocumentPaintIsValidPremultiplied(value)) {
        atomic_store_explicit(&reduction[1], 1u, memory_order_relaxed);
        return;
    }
    atomic_fetch_max_explicit(
        &reduction[0],
        as_type<uint>(value.a),
        memory_order_relaxed
    );
}

kernel void patternDocumentPaintResizeMutation(
    texture2d<float, access::read> source
        [[texture(PatternTextureIndexDocumentPaintBase)]],
    texture2d<float, access::write> destination
        [[texture(PatternTextureIndexDocumentPaintDestination)]],
    constant PatternDocumentPaintMutationUniforms& mutation
        [[buffer(PatternBufferIndexDocumentPaintMutationUniforms)]],
    constant PatternRadialFrameUniforms& targetRadial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    device atomic_uint* reduction
        [[buffer(PatternBufferIndexDocumentPaintMutationReduction)]],
    uint2 texel [[thread_position_in_grid]]
) {
    if (any(texel >= uint2(destination.get_width(), destination.get_height()))) {
        return;
    }
    if (any(texel >= mutation.logicalExtent)) {
        destination.write(float4(0.0), texel);
        return;
    }

    const bool atOrAfterDestination = all(texel >= mutation.destinationOrigin);
    const uint2 relative = atOrAfterDestination
        ? texel - mutation.destinationOrigin
        : uint2(0);
    bool shouldCopy = atOrAfterDestination && all(relative < mutation.copyExtent);
    if (
        shouldCopy
        && (mutation.flags & PatternDocumentPaintFlagRadialTargetMask) != 0
    ) {
        const int2 logicalTexel = mutation.logicalPage * 256 + int2(texel);
        shouldCopy = patternRadialOrbitIntersectsCanvas(
            float2(logicalTexel) + 0.5,
            targetRadial
        );
    }

    const uint2 sourceTexel = mutation.sourceOrigin + relative;
    const float4 value = shouldCopy ? source.read(sourceTexel) : float4(0.0);
    patternDocumentPaintStoreAndReduce(
        value,
        !shouldCopy || patternDocumentPaintIsValidPremultiplied(value),
        texel,
        mutation.logicalExtent,
        destination,
        reduction
    );
}

kernel void patternDocumentPaintEncodedImportMutation(
    texture2d<float, access::write> destination
        [[texture(PatternTextureIndexDocumentPaintDestination)]],
    constant PatternDocumentPaintMutationUniforms& mutation
        [[buffer(PatternBufferIndexDocumentPaintMutationUniforms)]],
    device atomic_uint* reduction
        [[buffer(PatternBufferIndexDocumentPaintMutationReduction)]],
    const device uchar* sourceBytes
        [[buffer(PatternBufferIndexDocumentPaintMutationSourceBytes)]],
    uint2 texel [[thread_position_in_grid]]
) {
    if (any(texel >= uint2(destination.get_width(), destination.get_height()))) {
        return;
    }
    if (any(texel >= mutation.logicalExtent)) {
        destination.write(float4(0.0), texel);
        return;
    }

    const uint offset = mutation.sourceByteOffset
        + texel.y * mutation.sourceBytesPerRow
        + texel.x * 4;
    const uint blueByte = uint(sourceBytes[offset]);
    const uint greenByte = uint(sourceBytes[offset + 1]);
    const uint redByte = uint(sourceBytes[offset + 2]);
    const uint alphaByte = uint(sourceBytes[offset + 3]);
    float4 value = float4(0.0);
    if (alphaByte != 0) {
        const float alpha = float(alphaByte) / 255.0;
        const float inverseAlphaByte = 1.0 / float(alphaByte);
        const float3 encodedStraight = clamp(
            float3(redByte, greenByte, blueByte) * inverseAlphaByte,
            0.0,
            1.0
        );
        value = float4(
            patternSRGBChannelToLinear(encodedStraight.r) * alpha,
            patternSRGBChannelToLinear(encodedStraight.g) * alpha,
            patternSRGBChannelToLinear(encodedStraight.b) * alpha,
            alpha
        );
    }
    patternDocumentPaintStoreAndReduce(
        value,
        true,
        texel,
        mutation.logicalExtent,
        destination,
        reduction
    );
}
