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

fragment float4 patternHardRoundStampFragment(
    PatternProjectedStampOut input [[stage_in]]
) {
    if (
        input.clipCount > 0
        && dot(input.clip0.xy, input.brushLocal) < input.clip0.z
    ) {
        discard_fragment();
    }
    if (
        input.clipCount > 1
        && dot(input.clip1.xy, input.brushLocal) < input.clip1.z
    ) {
        discard_fragment();
    }
    if (
        input.clipCount > 2
        && dot(input.clip2.xy, input.brushLocal) < input.clip2.z
    ) {
        discard_fragment();
    }
    if (
        input.clipCount > 3
        && dot(input.clip3.xy, input.brushLocal) < input.clip3.z
    ) {
        discard_fragment();
    }

    const float2 offsetPixels = input.brushLocal * input.radius;
    const float coverage = clamp(
        input.radius + 0.5 - length(offsetPixels),
        0.0,
        1.0
    );
    return float4(0.0, 0.0, 0.0, coverage);
}

static float2 patternPositiveFold(float2 world, float2 tileSize) {
    return world - floor(world / tileSize) * tileSize;
}

static float4 patternSourceOver(float4 source, float4 destination) {
    return source + destination * (1.0 - source.a);
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
    const float2 canonicalPixel = patternPositiveFold(world, frame.tileSize);
    const float2 uv = canonicalPixel / frame.tileSize;
    const float4 base = canonical.sample(tileSampler, uv);
    const float4 overlay = frame.liveVisible == 0
        ? float4(0.0)
        : live.sample(tileSampler, uv);
    float4 result = patternSourceOver(overlay, base);

    if (frame.showGridLines != 0) {
        const float2 edgeDistance = min(
            canonicalPixel,
            frame.tileSize - canonicalPixel
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
    return patternSourceOver(
        live.sample(tileSampler, uv),
        canonical.sample(tileSampler, uv)
    );
}
