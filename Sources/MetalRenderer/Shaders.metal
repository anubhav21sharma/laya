#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

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

struct PatternFullscreenOut {
    float4 position [[position]];
    float2 screenPixel;
};

struct PatternProjectedStampOut {
    float4 position [[position]];
    float2 canonical;
    float2 brushLocal;
    float radius [[flat]];
    uint clipCount [[flat]];
    float4 color [[flat]];
    float4 clip0 [[flat]];
    float4 clip1 [[flat]];
    float4 clip2 [[flat]];
    float4 clip3 [[flat]];
};

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

vertex PatternProjectedStampOut patternProjectedStampVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    const device PatternProjectedStampInstance* instances
        [[buffer(PatternBufferIndexDabInstances)]]
) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    const PatternProjectedStampInstance instance = instances[instanceID];
    const float normalizedExpansion = 1.0 + 1.0 / instance.radius;
    const float2 brushLocal = corners[vertexID] * normalizedExpansion;
    const float2 canonical =
        instance.canonicalTranslation
        + instance.canonicalXAxis * brushLocal.x
        + instance.canonicalYAxis * brushLocal.y;

    PatternProjectedStampOut output;
    output.position = float4(
        canonical.x / frame.tileSize.x * 2.0 - 1.0,
        1.0 - canonical.y / frame.tileSize.y * 2.0,
        0.0,
        1.0
    );
    output.canonical = canonical;
    output.brushLocal = brushLocal;
    output.radius = instance.radius;
    output.clipCount = instance.clipCount;
    output.color = instance.color;
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
    return output;
}

static bool patternProjectedStampInsideClip(
    PatternProjectedStampOut input
) {
    if (
        input.clipCount > 0
        && dot(input.clip0.xy, input.brushLocal) < input.clip0.z
    ) {
        return false;
    }
    if (
        input.clipCount > 1
        && dot(input.clip1.xy, input.brushLocal) < input.clip1.z
    ) {
        return false;
    }
    if (
        input.clipCount > 2
        && dot(input.clip2.xy, input.brushLocal) < input.clip2.z
    ) {
        return false;
    }
    if (
        input.clipCount > 3
        && dot(input.clip3.xy, input.brushLocal) < input.clip3.z
    ) {
        return false;
    }
    return true;
}

fragment float4 patternHardRoundStampFragment(
    PatternProjectedStampOut input [[stage_in]]
) {
    if (!patternProjectedStampInsideClip(input)) {
        discard_fragment();
    }

    const float2 offsetPixels = input.brushLocal * input.radius;
    const float coverage = clamp(
        input.radius + 0.5 - length(offsetPixels),
        0.0,
        1.0
    );
    return float4(input.color.rgb, input.color.a * coverage);
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
    PatternProjectedStampOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]]
) {
    if (
        !patternProjectedStampInsideClip(input)
        || !patternInsideAsymmetricTriangle(input.brushLocal)
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
            clamp(input.brushLocal * 0.5 + 0.5, 0.0, 1.0),
            0.0,
            1.0
        );
    default:
        return float4(1.0, 0.0, 1.0, 1.0);
    }
}

static float2 patternPositiveFold(float2 world, float2 tileSize) {
    return world - floor(world / tileSize) * tileSize;
}

static float patternPositiveFold(float coordinate, float extent) {
    return coordinate - floor(coordinate / extent) * extent;
}

struct PatternDisplayMapping {
    float2 canonicalPixel;
    float2 phasedCellLocal;
    bool valid;
};

static PatternDisplayMapping patternDisplayMapping(
    float2 world,
    float2 tileSize,
    uint tilingKind
) {
    switch (tilingKind) {
    case PatternTilingWireHalfDrop: {
        const int column = int(floor(world.x / tileSize.x));
        const float phaseY = (column & 1) * tileSize.y * 0.5;
        const float2 folded = patternPositiveFold(
            float2(world.x, world.y - phaseY),
            tileSize
        );
        return {folded, folded, true};
    }
    case PatternTilingWireBrick: {
        const int row = int(floor(world.y / tileSize.y));
        const float phaseX = (row & 1) * tileSize.x * 0.5;
        const float2 folded = patternPositiveFold(
            float2(world.x - phaseX, world.y),
            tileSize
        );
        return {folded, folded, true};
    }
    case PatternTilingWireMirrorX:
    case PatternTilingWireMirrorY:
    case PatternTilingWireMirrorXY: {
        const int column = int(floor(world.x / tileSize.x));
        const int row = int(floor(world.y / tileSize.y));
        const float2 local = patternPositiveFold(world, tileSize);
        const bool reflectsX =
            (
                tilingKind == PatternTilingWireMirrorX
                || tilingKind == PatternTilingWireMirrorXY
            )
            && (column & 1) != 0;
        const bool reflectsY =
            (
                tilingKind == PatternTilingWireMirrorY
                || tilingKind == PatternTilingWireMirrorXY
            )
            && (row & 1) != 0;
        const float2 canonical = float2(
            reflectsX
                ? patternPositiveFold(tileSize.x - local.x, tileSize.x)
                : local.x,
            reflectsY
                ? patternPositiveFold(tileSize.y - local.y, tileSize.y)
                : local.y
        );
        return {canonical, local, true};
    }
    case PatternTilingWireRotational: {
        const float2 folded = patternPositiveFold(world, tileSize);
        return {folded, folded, true};
    }
    case PatternTilingWireGrid: {
        const float2 folded = patternPositiveFold(world, tileSize);
        return {folded, folded, true};
    }
    default:
        return {float2(0.0), float2(0.0), false};
    }
}

static float4 patternSourceOver(float4 source, float4 destination) {
    return source + destination * (1.0 - source.a);
}

static float4 patternCompositeLive(
    float4 live,
    float4 canonical,
    uint compositeMode
) {
    if (compositeMode == PatternCompositeWireErase) {
        return canonical * (1.0 - live.a);
    }
    return patternSourceOver(live, canonical);
}

fragment float4 patternGridFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    texture2d<float> canonical [[texture(PatternTextureIndexCanonical)]],
    texture2d<float> live [[texture(PatternTextureIndexLive)]]
) {
    constexpr sampler tileSampler(
        coord::normalized,
        address::repeat,
        filter::linear
    );
    const float2 screenCenter = frame.drawableSize * 0.5;
    const float2 world = (input.screenPixel - screenCenter) / frame.zoom
        + frame.worldCenter;
    const PatternDisplayMapping mapping = patternDisplayMapping(
        world,
        frame.tileSize,
        frame.tilingKind
    );
    if (!mapping.valid) {
        return float4(1.0, 0.0, 1.0, 1.0);
    }
    const float2 uv = mapping.canonicalPixel / frame.tileSize;
    const float4 base = canonical.sample(tileSampler, uv);
    const float4 overlay = frame.liveVisible == 0
        ? float4(0.0)
        : live.sample(tileSampler, uv);
    float4 result = patternCompositeLive(
        overlay,
        base,
        frame.compositeMode
    );

    if (frame.showGridLines != 0) {
        const float2 edgeDistance = min(
            mapping.phasedCellLocal,
            frame.tileSize - mapping.phasedCellLocal
        ) * frame.zoom;
        const float coverage = 1.0 - smoothstep(
            frame.gridLineWidth,
            frame.gridLineWidth + 1.0,
            min(edgeDistance.x, edgeDistance.y)
        );
        const float alpha = 0.22 * coverage;
        const float4 grid = float4(
            float3(0.18, 0.20, 0.19) * alpha,
            alpha
        );
        result = patternSourceOver(grid, result);
    }

    return result;
}

fragment float4 patternCommitFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    texture2d<float> canonical [[texture(PatternTextureIndexCanonical)]],
    texture2d<float> live [[texture(PatternTextureIndexLive)]]
) {
    constexpr sampler tileSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::nearest
    );
    const float2 uv = input.screenPixel / frame.tileSize;
    return patternCompositeLive(
        live.sample(tileSampler, uv),
        canonical.sample(tileSampler, uv),
        frame.compositeMode
    );
}
