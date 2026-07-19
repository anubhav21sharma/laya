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

struct PatternDabOut {
    float4 position [[position]];
    float2 offsetPixels;
    float radius;
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

vertex PatternDabOut patternDabVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    const device PatternDabInstance* dabs
        [[buffer(PatternBufferIndexDabInstances)]]
) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    const PatternDabInstance dab = dabs[instanceID];
    const float expandedRadius = dab.radius + 1.0;
    const float2 offset = corners[vertexID] * expandedRadius;
    const float2 pixel = dab.center + offset;

    PatternDabOut output;
    output.position = float4(
        pixel.x / frame.tileSize.x * 2.0 - 1.0,
        1.0 - pixel.y / frame.tileSize.y * 2.0,
        0.0,
        1.0
    );
    output.offsetPixels = offset;
    output.radius = dab.radius;
    return output;
}

fragment float4 patternDabFragment(PatternDabOut input [[stage_in]]) {
    const float coverage = clamp(
        input.radius + 0.5 - length(input.offsetPixels),
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
