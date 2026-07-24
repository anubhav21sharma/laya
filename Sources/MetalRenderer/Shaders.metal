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
    float4 brushAttributes [[flat]];
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
    output.brushAttributes = instance.brushAttributes;
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

fragment float4 patternBrushStampFragment(
    PatternProjectedStampOut input [[stage_in]],
    constant PatternBrushMaterialUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    texture2d<float> shapeTexture
        [[texture(PatternTextureIndexBrushShape)]],
    texture2d<float> grainTexture
        [[texture(PatternTextureIndexBrushGrain)]]
) {
    if (!patternProjectedStampInsideClip(input)) {
        discard_fragment();
    }

    const float2 shapeUV = input.brushLocal * 0.5 + 0.5;
    if (any(shapeUV < 0.0) || any(shapeUV > 1.0)) {
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

    const float hardness = clamp(input.brushAttributes.x, 0.0, 1.0);
    float shapeCoverage;
    if (material.shapeKind == PatternShapeWireHardRound) {
        const float distance = length(input.brushLocal);
        if (hardness >= 0.9999) {
            const float2 offsetPixels = input.brushLocal * input.radius;
            shapeCoverage = clamp(
                input.radius + 0.5 - length(offsetPixels),
                0.0,
                1.0
            );
        } else {
            const float softness = max(1.0 / input.radius, (1.0 - hardness) * 0.5);
            shapeCoverage = 1.0 - smoothstep(
                1.0 - softness,
                1.0 + 0.5 / input.radius,
                distance
            );
        }
    } else {
        const float rawShape = shapeTexture.sample(shapeSampler, shapeUV).r;
        shapeCoverage = clamp(
            (rawShape - (1.0 - hardness)) / max(hardness, 1.0 / 255.0),
            0.0,
            1.0
        );
    }

    float grainCoverage = 1.0;
    if (material.grainKind != PatternGrainWireOpaque) {
        float2 baseGrainCoordinate;
        if (
            material.grainCoordinateMode
                == PatternGrainCoordinateWireBrushLocal
        ) {
            baseGrainCoordinate = shapeUV;
        } else {
            baseGrainCoordinate = input.canonical / 64.0;
        }
        const float grainCosine = cos(material.grainRotation);
        const float grainSine = sin(material.grainRotation);
        const float2 grainCoordinate = float2(
            grainCosine * baseGrainCoordinate.x
                - grainSine * baseGrainCoordinate.y,
            grainSine * baseGrainCoordinate.x
                + grainCosine * baseGrainCoordinate.y
        ) * input.brushAttributes.y + input.brushAttributes.zw;
        grainCoverage = grainTexture.sample(
            grainSampler,
            grainCoordinate
        ).r;
    }

    if (material.materialFamily == PatternMaterialWireBoundedWash) {
        shapeCoverage = pow(clamp(shapeCoverage, 0.0, 1.0), 0.72);
        grainCoverage = mix(
            grainCoverage,
            1.0,
            clamp(material.wetness, 0.0, 1.0) * 0.45
        );
    }

    const float coverage = shapeCoverage * grainCoverage;
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

static float patternPositiveFold(float coordinate, float extent) {
    const float remainder = fmod(coordinate, extent);
    if (remainder == 0.0) {
        return 0.0;
    }
    if (remainder < 0.0) {
        return min(
            remainder + extent,
            nextafter(extent, 0.0)
        );
    }
    return remainder;
}

static float2 patternPositiveFold(float2 world, float2 tileSize) {
    return float2(
        patternPositiveFold(world.x, tileSize.x),
        patternPositiveFold(world.y, tileSize.y)
    );
}

struct PatternDisplayMapping {
    float2 canonicalPixel;
    float2 phasedCellLocal;
    bool valid;
};

static PatternDisplayMapping patternDisplayMapping(
    float2 world,
    float2 tileSize,
    float2 repeatSize,
    float2 latticeXAxis,
    float2 latticeYAxis,
    float2 latticeTranslation,
    uint symmetryFamily,
    uint tilingKind
) {
    if (symmetryFamily != PatternSymmetryFamilyWireRectangular) {
        return {float2(0.0), float2(0.0), false};
    }

    const float2 lattice =
        latticeXAxis * world.x
        + latticeYAxis * world.y
        + latticeTranslation;

    switch (tilingKind) {
    case PatternTilingWireHalfDrop: {
        if (all(repeatSize == tileSize)) {
            const int column = int(floor(world.x / tileSize.x));
            const float phaseY = (column & 1) * tileSize.y * 0.5;
            const float2 folded = patternPositiveFold(
                float2(world.x, world.y - phaseY),
                tileSize
            );
            return {folded, folded, true};
        }
        const int column = int(floor(lattice.x));
        const float phaseY = (column & 1) * 0.5;
        const float2 foldedUnit = patternPositiveFold(
            float2(lattice.x, lattice.y - phaseY),
            float2(1.0)
        );
        return {
            foldedUnit * tileSize,
            foldedUnit * repeatSize,
            true
        };
    }
    case PatternTilingWireBrick: {
        if (all(repeatSize == tileSize)) {
            const int row = int(floor(world.y / tileSize.y));
            const float phaseX = (row & 1) * tileSize.x * 0.5;
            const float2 folded = patternPositiveFold(
                float2(world.x - phaseX, world.y),
                tileSize
            );
            return {folded, folded, true};
        }
        const int row = int(floor(lattice.y));
        const float phaseX = (row & 1) * 0.5;
        const float2 foldedUnit = patternPositiveFold(
            float2(lattice.x - phaseX, lattice.y),
            float2(1.0)
        );
        return {
            foldedUnit * tileSize,
            foldedUnit * repeatSize,
            true
        };
    }
    case PatternTilingWireMirrorX:
    case PatternTilingWireMirrorY:
    case PatternTilingWireMirrorXY: {
        if (all(repeatSize == tileSize)) {
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
                    ? patternPositiveFold(
                        tileSize.x - local.x,
                        tileSize.x
                    )
                    : local.x,
                reflectsY
                    ? patternPositiveFold(
                        tileSize.y - local.y,
                        tileSize.y
                    )
                    : local.y
            );
            return {canonical, local, true};
        }
        const int column = int(floor(lattice.x));
        const int row = int(floor(lattice.y));
        const float2 localUnit = patternPositiveFold(
            lattice,
            float2(1.0)
        );
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
        const float2 canonicalUnit = float2(
            reflectsX
                ? patternPositiveFold(1.0 - localUnit.x, 1.0)
                : localUnit.x,
            reflectsY
                ? patternPositiveFold(1.0 - localUnit.y, 1.0)
                : localUnit.y
        );
        return {
            canonicalUnit * tileSize,
            localUnit * repeatSize,
            true
        };
    }
    case PatternTilingWireRotational:
    case PatternTilingWireGrid: {
        if (all(repeatSize == tileSize)) {
            const float2 folded = patternPositiveFold(world, tileSize);
            return {folded, folded, true};
        }
        const float2 foldedUnit = patternPositiveFold(
            lattice,
            float2(1.0)
        );
        return {
            foldedUnit * tileSize,
            foldedUnit * repeatSize,
            true
        };
    }
    case PatternTilingWireSquareRotation:
    case PatternTilingWireSquareKaleidoscope: {
        const float2 foldedUnit = patternPositiveFold(
            lattice,
            float2(1.0)
        );
        return {
            foldedUnit * tileSize,
            foldedUnit * repeatSize,
            true
        };
    }
    default:
        return {float2(0.0), float2(0.0), false};
    }
}

static PatternDisplayMapping patternTriangularDisplayMapping(
    float2 world,
    float2 tileSize,
    float2 repeatSize,
    float2 latticeXAxis,
    float2 latticeYAxis,
    float2 latticeTranslation,
    uint symmetryFamily,
    uint tilingKind
) {
    if (symmetryFamily != PatternSymmetryFamilyWireTriangular) {
        return {float2(0.0), float2(0.0), false};
    }
    switch (tilingKind) {
    case PatternTilingWireHexagons:
    case PatternTilingWireRotation3:
    case PatternTilingWireRotation6:
    case PatternTilingWireKaleidoscope60:
    case PatternTilingWireKaleidoscope30: {
        const float2 lattice =
            latticeXAxis * world.x
            + latticeYAxis * world.y
            + latticeTranslation;
        const float2 foldedUnit = patternPositiveFold(
            lattice,
            float2(1.0)
        );
        return {
            foldedUnit * tileSize,
            foldedUnit * repeatSize,
            true
        };
    }
    default:
        return {float2(0.0), float2(0.0), false};
    }
}

static float4 patternSourceOver(float4 source, float4 destination) {
    return source + destination * (1.0 - source.a);
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

static uint patternWrappedTexelIndex(int index, uint size) {
    const int signedSize = int(size);
    const int remainder = index % signedSize;
    return uint(remainder < 0 ? remainder + signedSize : remainder);
}

static uint2 patternWrappedTexel(
    int2 texel,
    uint2 textureSize
) {
    return uint2(
        patternWrappedTexelIndex(texel.x, textureSize.x),
        patternWrappedTexelIndex(texel.y, textureSize.y)
    );
}

static bool patternRadialAtlasTexel(
    int2 logicalTexel,
    constant PatternRadialFrameUniforms& radial,
    texture2d<int, access::read> pageTable,
    thread uint2& atlasTexel
);

static bool patternRadialOrbitIntersectsCanvas(
    float2 logicalPoint,
    constant PatternRadialFrameUniforms& radial
);

fragment float4 patternWashClearFragment(
    PatternFullscreenOut input [[stage_in]]
) {
    return float4(0.0);
}

static bool patternWashRegionContains(
    uint2 texel,
    const device int4* regions,
    uint regionCount
) {
    const int2 point = int2(texel);
    for (uint index = 0; index < regionCount; ++index) {
        const int4 region = regions[index];
        if (
            point.x >= region.x && point.y >= region.y
            && point.x < region.z && point.y < region.w
        ) {
            return true;
        }
    }
    return false;
}

static float4 patternWashRead(
    texture2d<float> source,
    int2 texel,
    const device int4* regions,
    uint regionCount,
    constant PatternGridFrameUniforms& frame,
    constant PatternRadialFrameUniforms& radial,
    constant PatternRadialResizePageUniforms& page,
    texture2d<int, access::read> pageTable
) {
    if (frame.tilingKind == PatternTilingWirePlainCanvas) {
        if (
            any(texel < int2(0))
            || texel.x >= int(source.get_width())
            || texel.y >= int(source.get_height())
        ) {
            return float4(0.0);
        }
        const uint2 direct = uint2(texel);
        return patternWashRegionContains(direct, regions, regionCount)
            ? source.read(direct)
            : float4(0.0);
    }
    if (frame.symmetryFamily == PatternSymmetryFamilyWireRadial) {
        const int side = int(radial.pageSide);
        const int2 atlasPage = int2(
            int(page.destinationSlot) % int(radial.atlasColumns),
            int(page.destinationSlot) / int(radial.atlasColumns)
        );
        const float2 logicalPixel = float2(
            int2(page.logicalPageX, page.logicalPageY) * side
                + texel - atlasPage * side
        ) + 0.5;
        const float radius = length(logicalPixel);
        float2 folded = logicalPixel;
        if (radius > 0.0) {
            const float fullTurn = 2.0 * M_PI_F;
            float angle = atan2(logicalPixel.y, logicalPixel.x);
            angle = fmod(angle, fullTurn);
            if (angle < 0.0) {
                angle += fullTurn;
            }
            const uint sector = min(
                uint(floor(angle / radial.sectorAngle)),
                radial.displayedSectorCount - 1
            );
            float localAngle =
                angle - float(sector) * radial.sectorAngle;
            if (radial.dihedral != 0 && (sector & 1u) != 0) {
                localAngle = radial.sectorAngle - localAngle;
            }
            folded = radius * float2(
                cos(localAngle),
                sin(localAngle)
            );
        }
        if (!patternRadialOrbitIntersectsCanvas(folded, radial)) {
            return float4(0.0);
        }
        const float2 samplePosition = folded - 0.5;
        const int2 lower = int2(floor(samplePosition));
        const float2 blend = fract(samplePosition);
        float4 samples[4];
        const int2 offsets[4] = {
            int2(0, 0),
            int2(1, 0),
            int2(0, 1),
            int2(1, 1),
        };
        for (uint index = 0; index < 4; ++index) {
            uint2 atlasTexel;
            samples[index] = (
                patternRadialAtlasTexel(
                    lower + offsets[index],
                    radial,
                    pageTable,
                    atlasTexel
                )
                && patternWashRegionContains(
                    atlasTexel,
                    regions,
                    regionCount
                )
            ) ? source.read(atlasTexel) : float4(0.0);
        }
        return mix(
            mix(samples[0], samples[1], blend.x),
            mix(samples[2], samples[3], blend.x),
            blend.y
        );
    }
    const uint2 wrapped = patternWrappedTexel(
        texel,
        uint2(source.get_width(), source.get_height())
    );
    return patternWashRegionContains(wrapped, regions, regionCount)
        ? source.read(wrapped)
        : float4(0.0);
}

static float4 patternLimitWashAccumulation(
    float4 value,
    float accumulationLimit
) {
    const float alpha = clamp(value.a, 0.0, 1.0);
    const float limitedAlpha = min(
        alpha,
        clamp(accumulationLimit, 0.0, 1.0)
    );
    if (alpha <= 0.000001) {
        return float4(0.0);
    }
    return float4(
        max(value.rgb, float3(0.0)) * (limitedAlpha / alpha),
        limitedAlpha
    );
}

fragment float4 patternWashSoftenFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternBrushMaterialUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    const device int4* processingRegions
        [[buffer(PatternBufferIndexDabInstances)]],
    constant PatternRadialFrameUniforms& radial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    constant PatternRadialResizePageUniforms& page
        [[buffer(PatternBufferIndexRadialResizePage)]],
    texture2d<float> source [[texture(PatternTextureIndexCanonical)]],
    texture2d<int, access::read> pageTable
        [[texture(PatternTextureIndexRadialPageTable)]]
) {
    const int2 centerTexel = int2(input.screenPixel);
    const uint passCount = max(material.softenPasses, 1u);
    const int radius = material.bleedRadius <= 0.0
        ? 0
        : max(1, int(ceil(material.bleedRadius / float(passCount))));
    const int2 dx = int2(radius, 0);
    const int2 dy = int2(0, radius);

    const float4 center = patternWashRead(
        source,
        centerTexel,
        processingRegions,
        material.padding1,
        frame,
        radial,
        page,
        pageTable
    );
    float4 softened = center * 4.0;
    softened += patternWashRead(
        source, centerTexel - dx, processingRegions, material.padding1,
        frame, radial, page, pageTable
    ) * 2.0;
    softened += patternWashRead(
        source, centerTexel + dx, processingRegions, material.padding1,
        frame, radial, page, pageTable
    ) * 2.0;
    softened += patternWashRead(
        source, centerTexel - dy, processingRegions, material.padding1,
        frame, radial, page, pageTable
    ) * 2.0;
    softened += patternWashRead(
        source, centerTexel + dy, processingRegions, material.padding1,
        frame, radial, page, pageTable
    ) * 2.0;
    softened += patternWashRead(
        source, centerTexel - dx - dy, processingRegions, material.padding1,
        frame, radial, page, pageTable
    );
    softened += patternWashRead(
        source, centerTexel + dx - dy, processingRegions, material.padding1,
        frame, radial, page, pageTable
    );
    softened += patternWashRead(
        source, centerTexel - dx + dy, processingRegions, material.padding1,
        frame, radial, page, pageTable
    );
    softened += patternWashRead(
        source, centerTexel + dx + dy, processingRegions, material.padding1,
        frame, radial, page, pageTable
    );
    softened /= 16.0;

    const float wetness = clamp(material.wetness, 0.0, 1.0);
    return patternLimitWashAccumulation(
        mix(center, softened, wetness),
        material.accumulationLimit
    );
}

fragment float4 patternWashResolveFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternBrushMaterialUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternRadialFrameUniforms& radial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    constant PatternRadialResizePageUniforms& page
        [[buffer(PatternBufferIndexRadialResizePage)]],
    texture2d<float> source [[texture(PatternTextureIndexCanonical)]]
) {
    const uint2 texel = uint2(input.screenPixel);
    if (
        frame.symmetryFamily == PatternSymmetryFamilyWireRadial
        && frame.tilingKind != PatternTilingWirePlainCanvas
    ) {
        const int side = int(radial.pageSide);
        const int2 atlasPage = int2(
            int(page.destinationSlot) % int(radial.atlasColumns),
            int(page.destinationSlot) / int(radial.atlasColumns)
        );
        const float2 logicalPixel = float2(
            int2(page.logicalPageX, page.logicalPageY) * side
                + int2(texel) - atlasPage * side
        ) + 0.5;
        const float angle = atan2(logicalPixel.y, logicalPixel.x);
        const float tolerance = 0.0001;
        if (
            angle < -tolerance
            || angle > radial.sectorAngle + tolerance
            || !patternRadialOrbitIntersectsCanvas(logicalPixel, radial)
        ) {
            return float4(0.0);
        }
    }
    return patternLimitWashAccumulation(
        source.read(texel),
        material.accumulationLimit
    );
}

static float4 patternCompositeThenBilinearSample(
    texture2d<float> canonical,
    texture2d<float> settledLive,
    texture2d<float> replayLive,
    float2 canonicalPixel,
    uint compositeMode,
    uint liveVisible,
    float strokeOpacity,
    float accumulationLimit,
    float eraserStrength
) {
    const float2 samplePosition = canonicalPixel - 0.5;
    const int2 lower = int2(floor(samplePosition));
    const float2 blend = fract(samplePosition);
    const uint2 textureSize = uint2(
        canonical.get_width(),
        canonical.get_height()
    );
    const uint2 texel00 = patternWrappedTexel(lower, textureSize);
    const uint2 texel10 = patternWrappedTexel(
        lower + int2(1, 0),
        textureSize
    );
    const uint2 texel01 = patternWrappedTexel(
        lower + int2(0, 1),
        textureSize
    );
    const uint2 texel11 = patternWrappedTexel(
        lower + int2(1, 1),
        textureSize
    );
    const float4 live00 = liveVisible == 0
        ? float4(0.0)
        : settledLive.read(texel00);
    const float4 live10 = liveVisible == 0
        ? float4(0.0)
        : settledLive.read(texel10);
    const float4 live01 = liveVisible == 0
        ? float4(0.0)
        : settledLive.read(texel01);
    const float4 live11 = liveVisible == 0
        ? float4(0.0)
        : settledLive.read(texel11);
    const float4 replay00 = liveVisible == 0
        ? float4(0.0)
        : replayLive.read(texel00);
    const float4 replay10 = liveVisible == 0
        ? float4(0.0)
        : replayLive.read(texel10);
    const float4 replay01 = liveVisible == 0
        ? float4(0.0)
        : replayLive.read(texel01);
    const float4 replay11 = liveVisible == 0
        ? float4(0.0)
        : replayLive.read(texel11);
    const float4 composite00 = patternCompositeLive(
        live00,
        replay00,
        canonical.read(texel00),
        compositeMode,
        strokeOpacity,
        accumulationLimit,
        eraserStrength
    );
    const float4 composite10 = patternCompositeLive(
        live10,
        replay10,
        canonical.read(texel10),
        compositeMode,
        strokeOpacity,
        accumulationLimit,
        eraserStrength
    );
    const float4 composite01 = patternCompositeLive(
        live01,
        replay01,
        canonical.read(texel01),
        compositeMode,
        strokeOpacity,
        accumulationLimit,
        eraserStrength
    );
    const float4 composite11 = patternCompositeLive(
        live11,
        replay11,
        canonical.read(texel11),
        compositeMode,
        strokeOpacity,
        accumulationLimit,
        eraserStrength
    );
    return mix(
        mix(composite00, composite10, blend.x),
        mix(composite01, composite11, blend.x),
        blend.y
    );
}

static float4 patternWrappedBilinearCanonicalSample(
    texture2d<float> canonical,
    float2 canonicalPixel
) {
    const float2 samplePosition = canonicalPixel - 0.5;
    const int2 lower = int2(floor(samplePosition));
    const float2 blend = fract(samplePosition);
    const uint2 textureSize = uint2(
        canonical.get_width(),
        canonical.get_height()
    );
    const float4 value00 = canonical.read(
        patternWrappedTexel(lower, textureSize)
    );
    const float4 value10 = canonical.read(
        patternWrappedTexel(lower + int2(1, 0), textureSize)
    );
    const float4 value01 = canonical.read(
        patternWrappedTexel(lower + int2(0, 1), textureSize)
    );
    const float4 value11 = canonical.read(
        patternWrappedTexel(lower + int2(1, 1), textureSize)
    );
    return mix(
        mix(value00, value10, blend.x),
        mix(value01, value11, blend.x),
        blend.y
    );
}

fragment float4 patternPeriodicRepeatExportFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    texture2d<float> canonical [[texture(PatternTextureIndexCanonical)]]
) {
    const float2 canonicalPixel =
        input.screenPixel / frame.drawableSize * frame.tileSize;
    return patternWrappedBilinearCanonicalSample(
        canonical,
        canonicalPixel
    );
}

static float patternDistanceToNearestInteger(float value) {
    const float folded = fract(value);
    return min(folded, 1.0 - folded);
}

static float2 patternTriangularAxial(
    float2 local,
    float spacing
) {
    const float inverseSqrtThree = 0.57735026919;
    const float row = 2.0 * local.y * inverseSqrtThree / spacing;
    return float2(local.x / spacing - row * 0.5, row);
}

static float patternTriangularEdgeDistance(
    float2 local,
    float spacing
) {
    const float2 axial = patternTriangularAxial(local, spacing);
    const float altitude = 0.86602540378 * spacing;
    return min(
        min(
            patternDistanceToNearestInteger(axial.x),
            patternDistanceToNearestInteger(axial.y)
        ),
        patternDistanceToNearestInteger(axial.x + axial.y)
    ) * altitude;
}

static float2 patternNearestTriangularLatticePoint(
    float2 local,
    float spacing
) {
    const float2 axial = patternTriangularAxial(local, spacing);
    float cubeX = round(axial.x);
    float cubeZ = round(axial.y);
    float cubeY = round(-axial.x - axial.y);
    const float differenceX = abs(cubeX - axial.x);
    const float differenceZ = abs(cubeZ - axial.y);
    const float differenceY = abs(cubeY + axial.x + axial.y);
    if (differenceX > differenceY && differenceX > differenceZ) {
        cubeX = -cubeY - cubeZ;
    } else if (differenceY > differenceZ) {
        cubeY = -cubeX - cubeZ;
    } else {
        cubeZ = -cubeX - cubeY;
    }
    return float2(
        (cubeX + cubeZ * 0.5) * spacing,
        cubeZ * 0.86602540378 * spacing
    );
}

static float patternHexagonEdgeDistance(
    float2 local,
    float spacing
) {
    const float2 relative = local
        - patternNearestTriangularLatticePoint(local, spacing);
    const float apothem = spacing * 0.5;
    const float first = apothem - abs(relative.x);
    const float second = apothem - abs(
        dot(relative, float2(0.5, 0.86602540378))
    );
    const float third = apothem - abs(
        dot(relative, float2(-0.5, 0.86602540378))
    );
    return max(min(first, min(second, third)), 0.0);
}

static float patternGuideRingDistance(
    float2 local,
    float2 repeatSize,
    float2 normalizedCenter,
    float zoom,
    float radius
) {
    return abs(
        length(local - normalizedCenter * repeatSize) * zoom - radius
    );
}

static float patternTriangularCenterDistance(
    float2 local,
    float2 repeatSize,
    uint guideKind,
    float zoom
) {
    float distance = INFINITY;
    if (
        guideKind == PatternGuideWireTriangularRotation3
        || guideKind == PatternGuideWireTriangularKaleidoscope60
        || guideKind == PatternGuideWireTriangularRotation6
        || guideKind == PatternGuideWireTriangularKaleidoscope30
    ) {
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.0, 0.0), zoom, 4.0
        ));
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.5, 1.0 / 6.0), zoom, 3.0
        ));
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.0, 1.0 / 3.0), zoom, 3.0
        ));
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.5, 0.5), zoom, 4.0
        ));
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.0, 2.0 / 3.0), zoom, 3.0
        ));
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.5, 5.0 / 6.0), zoom, 3.0
        ));
    }
    if (
        guideKind == PatternGuideWireTriangularRotation6
        || guideKind == PatternGuideWireTriangularKaleidoscope30
    ) {
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.5, 0.0), zoom, 2.5
        ));
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.25, 0.25), zoom, 2.5
        ));
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.75, 0.25), zoom, 2.5
        ));
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.0, 0.5), zoom, 2.5
        ));
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.25, 0.75), zoom, 2.5
        ));
        distance = min(distance, patternGuideRingDistance(
            local, repeatSize, float2(0.75, 0.75), zoom, 2.5
        ));
    }
    return distance;
}

static float4 patternGridOverlay(
    float4 color,
    PatternDisplayMapping mapping,
    constant PatternGridFrameUniforms& frame
) {
    if (frame.showGridLines != 0) {
        const float2 edgeDistance = min(
            mapping.phasedCellLocal,
            frame.repeatSize - mapping.phasedCellLocal
        );
        float guideDistance = min(edgeDistance.x, edgeDistance.y)
            * frame.zoom;
        const float2 centerRelative =
            mapping.phasedCellLocal - frame.repeatSize * 0.5;
        if (
            frame.guideKind == PatternGuideWireSquareRotation
            || frame.guideKind == PatternGuideWireSquareKaleidoscope
        ) {
            const float cornerRingDistance = abs(
                length(edgeDistance) * frame.zoom - 4.0
            );
            const float centerRingDistance = abs(
                length(centerRelative) * frame.zoom - 4.0
            );
            const float edgeCenterRingDistance = abs(
                min(
                    length(float2(abs(centerRelative.x), edgeDistance.y)),
                    length(float2(edgeDistance.x, abs(centerRelative.y)))
                ) * frame.zoom - 3.0
            );
            guideDistance = min(
                guideDistance,
                min(
                    cornerRingDistance,
                    min(centerRingDistance, edgeCenterRingDistance)
                )
            );
        }
        if (
            frame.guideKind == PatternGuideWireSquareKaleidoscope
        ) {
            const float inverseSquareRootTwo = 0.70710678118;
            const float mirrorDistance = min(
                min(abs(centerRelative.x), abs(centerRelative.y)),
                min(
                    abs(centerRelative.x - centerRelative.y)
                        * inverseSquareRootTwo,
                    abs(centerRelative.x + centerRelative.y)
                        * inverseSquareRootTwo
                )
            ) * frame.zoom;
            guideDistance = min(guideDistance, mirrorDistance);
        }
        const float coverage = 1.0 - smoothstep(
            frame.gridLineWidth,
            frame.gridLineWidth + 1.0,
            guideDistance
        );
        const float alpha = 0.22 * coverage;
        const float4 grid = float4(
            float3(0.18, 0.20, 0.19) * alpha,
            alpha
        );
        return patternSourceOver(grid, color);
    }
    return color;
}

static float4 patternTriangularGridOverlay(
    float4 color,
    PatternDisplayMapping mapping,
    constant PatternGridFrameUniforms& frame
) {
    if (frame.showGridLines != 0) {
        const float2 edgeDistance = min(
            mapping.phasedCellLocal,
            frame.repeatSize - mapping.phasedCellLocal
        );
        float guideDistance = min(edgeDistance.x, edgeDistance.y)
            * frame.zoom;
        const float spacing = frame.repeatSize.x;
        const float triangularDistance = patternTriangularEdgeDistance(
            mapping.phasedCellLocal,
            spacing
        ) * frame.zoom;
        const float hexagonDistance = patternHexagonEdgeDistance(
            mapping.phasedCellLocal,
            spacing
        ) * frame.zoom;
        if (frame.guideKind == PatternGuideWireHexagons) {
            guideDistance = min(guideDistance, hexagonDistance);
        } else if (
            frame.guideKind == PatternGuideWireTriangularKaleidoscope30
        ) {
            guideDistance = min(
                guideDistance,
                min(triangularDistance, hexagonDistance)
            );
        } else {
            guideDistance = min(guideDistance, triangularDistance);
        }
        guideDistance = min(
            guideDistance,
            patternTriangularCenterDistance(
                mapping.phasedCellLocal,
                frame.repeatSize,
                frame.guideKind,
                frame.zoom
            )
        );
        const float coverage = 1.0 - smoothstep(
            frame.gridLineWidth,
            frame.gridLineWidth + 1.0,
            guideDistance
        );
        const float alpha = 0.22 * coverage;
        const float4 grid = float4(
            float3(0.18, 0.20, 0.19) * alpha,
            alpha
        );
        return patternSourceOver(grid, color);
    }
    return color;
}

fragment float4 patternGridFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternBrushMaterialUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    texture2d<float> canonical [[texture(PatternTextureIndexCanonical)]],
    texture2d<float> live [[texture(PatternTextureIndexLive)]],
    texture2d<float> replayLive [[texture(PatternTextureIndexReplayLive)]]
) {
    const float2 screenCenter = frame.drawableSize * 0.5;
    const float2 world = (input.screenPixel - screenCenter) / frame.zoom
        + frame.worldCenter;
    const PatternDisplayMapping mapping = patternDisplayMapping(
        world,
        frame.tileSize,
        frame.repeatSize,
        frame.latticeXAxis,
        frame.latticeYAxis,
        frame.latticeTranslation,
        frame.symmetryFamily,
        frame.tilingKind
    );
    if (!mapping.valid) {
        return float4(1.0, 0.0, 1.0, 1.0);
    }
    float4 result = patternCompositeThenBilinearSample(
        canonical,
        live,
        replayLive,
        mapping.canonicalPixel,
        frame.compositeMode,
        frame.liveVisible,
        material.strokeOpacity,
        material.accumulationLimit,
        material.materialStrength
    );

    return patternGridOverlay(result, mapping, frame);
}

fragment float4 patternTriangularGridFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternBrushMaterialUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    texture2d<float> canonical [[texture(PatternTextureIndexCanonical)]],
    texture2d<float> live [[texture(PatternTextureIndexLive)]],
    texture2d<float> replayLive [[texture(PatternTextureIndexReplayLive)]]
) {
    const float2 screenCenter = frame.drawableSize * 0.5;
    const float2 world = (input.screenPixel - screenCenter) / frame.zoom
        + frame.worldCenter;
    const PatternDisplayMapping mapping = patternTriangularDisplayMapping(
        world,
        frame.tileSize,
        frame.repeatSize,
        frame.latticeXAxis,
        frame.latticeYAxis,
        frame.latticeTranslation,
        frame.symmetryFamily,
        frame.tilingKind
    );
    if (!mapping.valid) {
        return float4(1.0, 0.0, 1.0, 1.0);
    }
    float4 result = patternCompositeThenBilinearSample(
        canonical,
        live,
        replayLive,
        mapping.canonicalPixel,
        frame.compositeMode,
        frame.liveVisible,
        material.strokeOpacity,
        material.accumulationLimit,
        material.materialStrength
    );

    return patternTriangularGridOverlay(result, mapping, frame);
}

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
    return {
        radius * float2(cos(localAngle), sin(localAngle)),
        radius,
        angle,
        true
    };
}

static bool patternRadialAtlasTexel(
    int2 logicalTexel,
    constant PatternRadialFrameUniforms& radial,
    texture2d<int, access::read> pageTable,
    thread uint2& atlasTexel
) {
    const int side = int(radial.pageSide);
    const int2 page = int2(floor(float2(logicalTexel) / float(side)));
    const int2 table = page - int2(radial.pageOrigin);
    if (
        any(table < int2(0))
        || any(table >= int2(radial.pageTableSize))
    ) {
        return false;
    }
    const int slot = pageTable.read(uint2(table)).x;
    if (slot < 0) {
        return false;
    }
    const int2 local = logicalTexel - page * side;
    const int2 atlasPage = int2(
        slot % int(radial.atlasColumns),
        slot / int(radial.atlasColumns)
    );
    atlasTexel = uint2(atlasPage * side + local);
    return true;
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

kernel void patternRadialResizeCopy(
    texture2d<float, access::read> source
        [[texture(PatternTextureIndexCanonical)]],
    texture2d<float, access::write> destination
        [[texture(PatternTextureIndexLive)]],
    texture2d<int, access::read> sourcePageTable
        [[texture(PatternTextureIndexRadialPageTable)]],
    constant PatternRadialFrameUniforms& sourceRadial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    constant PatternRadialFrameUniforms& destinationRadial
        [[buffer(PatternBufferIndexRadialResizeDestinationUniforms)]],
    constant PatternRadialResizePageUniforms& page
        [[buffer(PatternBufferIndexRadialResizePage)]],
    uint2 localTexel [[thread_position_in_grid]]
) {
    const uint side = destinationRadial.pageSide;
    if (localTexel.x >= side || localTexel.y >= side) {
        return;
    }
    const int2 logicalTexel = int2(
        page.logicalPageX * int(side) + int(localTexel.x),
        page.logicalPageY * int(side) + int(localTexel.y)
    );
    const float2 logicalPoint = float2(logicalTexel) + 0.5;
    const uint2 destinationPage = uint2(
        page.destinationSlot % destinationRadial.atlasColumns,
        page.destinationSlot / destinationRadial.atlasColumns
    );
    const uint2 destinationTexel = destinationPage * side + localTexel;
    uint2 sourceTexel;
    if (
        patternRadialOrbitIntersectsCanvas(
            logicalPoint,
            destinationRadial
        )
        && patternRadialAtlasTexel(
            logicalTexel,
            sourceRadial,
            sourcePageTable,
            sourceTexel
        )
    ) {
        destination.write(source.read(sourceTexel), destinationTexel);
    } else {
        destination.write(float4(0.0), destinationTexel);
    }
}

static float4 patternRadialCompositeTexel(
    texture2d<float> canonical,
    texture2d<float> settledLive,
    texture2d<float> replayLive,
    texture2d<int, access::read> pageTable,
    int2 logicalTexel,
    constant PatternGridFrameUniforms& frame,
    constant PatternRadialFrameUniforms& radial,
    constant PatternBrushMaterialUniforms& material
) {
    uint2 atlasTexel;
    if (!patternRadialAtlasTexel(
        logicalTexel,
        radial,
        pageTable,
        atlasTexel
    )) {
        return float4(0.0);
    }
    const float4 settled = frame.liveVisible == 0
        ? float4(0.0)
        : settledLive.read(atlasTexel);
    const float4 replay = frame.liveVisible == 0
        ? float4(0.0)
        : replayLive.read(atlasTexel);
    return patternCompositeLive(
        settled,
        replay,
        canonical.read(atlasTexel),
        frame.compositeMode,
        material.strokeOpacity,
        material.accumulationLimit,
        material.materialStrength
    );
}

static float4 patternRadialBilinearComposite(
    texture2d<float> canonical,
    texture2d<float> settledLive,
    texture2d<float> replayLive,
    texture2d<int, access::read> pageTable,
    float2 logicalPixel,
    constant PatternGridFrameUniforms& frame,
    constant PatternRadialFrameUniforms& radial,
    constant PatternBrushMaterialUniforms& material
) {
    const float2 samplePosition = logicalPixel - 0.5;
    const int2 lower = int2(floor(samplePosition));
    const float2 blend = fract(samplePosition);
    const float4 value00 = patternRadialCompositeTexel(
        canonical, settledLive, replayLive, pageTable, lower,
        frame, radial, material
    );
    const float4 value10 = patternRadialCompositeTexel(
        canonical, settledLive, replayLive, pageTable,
        lower + int2(1, 0), frame, radial, material
    );
    const float4 value01 = patternRadialCompositeTexel(
        canonical, settledLive, replayLive, pageTable,
        lower + int2(0, 1), frame, radial, material
    );
    const float4 value11 = patternRadialCompositeTexel(
        canonical, settledLive, replayLive, pageTable,
        lower + int2(1, 1), frame, radial, material
    );
    return mix(
        mix(value00, value10, blend.x),
        mix(value01, value11, blend.x),
        blend.y
    );
}

static float4 patternRadialGuideOverlay(
    float4 color,
    PatternRadialMapping mapping,
    constant PatternGridFrameUniforms& frame,
    constant PatternRadialFrameUniforms& radial
) {
    if (
        frame.showGridLines == 0
        || frame.tilingKind == PatternTilingWirePlainCanvas
    ) {
        return color;
    }
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
    const float centerDistance = abs(mapping.radius * frame.zoom - 4.0);
    const float guideDistance = min(axisDistance, centerDistance);
    const float coverage = 1.0 - smoothstep(
        frame.gridLineWidth,
        frame.gridLineWidth + 1.0,
        guideDistance
    );
    const float alpha = 0.24 * coverage;
    return patternSourceOver(
        float4(float3(0.18, 0.20, 0.19) * alpha, alpha),
        color
    );
}

static float4 patternFiniteBilinearComposite(
    texture2d<float> canonical,
    texture2d<float> settledLive,
    texture2d<float> replayLive,
    float2 canonicalPixel,
    constant PatternGridFrameUniforms& frame,
    constant PatternBrushMaterialUniforms& material
) {
    constexpr sampler finiteSampler(
        coord::normalized,
        address::clamp_to_zero,
        filter::linear
    );
    const float2 size = float2(
        canonical.get_width(),
        canonical.get_height()
    );
    const float2 uv = canonicalPixel / size;
    const float4 settled = frame.liveVisible == 0
        ? float4(0.0)
        : settledLive.sample(finiteSampler, uv);
    const float4 replay = frame.liveVisible == 0
        ? float4(0.0)
        : replayLive.sample(finiteSampler, uv);
    return patternCompositeLive(
        settled,
        replay,
        canonical.sample(finiteSampler, uv),
        frame.compositeMode,
        material.strokeOpacity,
        material.accumulationLimit,
        material.materialStrength
    );
}

fragment float4 patternRadialGridFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternBrushMaterialUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    constant PatternRadialFrameUniforms& radial
        [[buffer(PatternBufferIndexRadialFrameUniforms)]],
    texture2d<float> canonical [[texture(PatternTextureIndexCanonical)]],
    texture2d<float> live [[texture(PatternTextureIndexLive)]],
    texture2d<float> replayLive [[texture(PatternTextureIndexReplayLive)]],
    texture2d<int, access::read> pageTable
        [[texture(PatternTextureIndexRadialPageTable)]]
) {
    const float2 screenCenter = frame.drawableSize * 0.5;
    const float2 world = (input.screenPixel - screenCenter) / frame.zoom
        + frame.worldCenter;
    const PatternRadialMapping mapping = patternRadialMapping(
        world,
        frame,
        radial
    );
    if (!mapping.valid) {
        return float4(0.0);
    }
    float4 result;
    if (frame.tilingKind == PatternTilingWirePlainCanvas) {
        result = patternFiniteBilinearComposite(
            canonical,
            live,
            replayLive,
            mapping.logicalPixel,
            frame,
            material
        );
    } else {
        result = patternRadialBilinearComposite(
            canonical,
            live,
            replayLive,
            pageTable,
            mapping.logicalPixel,
            frame,
            radial,
            material
        );
    }
    return patternRadialGuideOverlay(result, mapping, frame, radial);
}

fragment float4 patternCommitFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    constant PatternBrushMaterialUniforms& material
        [[buffer(PatternBufferIndexBrushMaterial)]],
    texture2d<float> canonical [[texture(PatternTextureIndexCanonical)]],
    texture2d<float> live [[texture(PatternTextureIndexLive)]],
    texture2d<float> replayLive [[texture(PatternTextureIndexReplayLive)]]
) {
    constexpr sampler tileSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::nearest
    );
    const float2 uv = input.screenPixel / frame.tileSize;
    return patternCompositeLive(
        live.sample(tileSampler, uv),
        replayLive.sample(tileSampler, uv),
        canonical.sample(tileSampler, uv),
        frame.compositeMode,
        material.strokeOpacity,
        material.accumulationLimit,
        material.materialStrength
    );
}
