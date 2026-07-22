#ifndef PATTERN_SHADER_TYPES_H
#define PATTERN_SHADER_TYPES_H

#ifdef __METAL_VERSION__
#include <metal_stdlib>
using namespace metal;
typedef uint PatternUInt32;
typedef float2 PatternFloat2;
typedef float4 PatternFloat4;
#define PATTERN_WIRE_CONSTANT constant
#else
#include <stdint.h>
#include <simd/simd.h>
typedef uint32_t PatternUInt32;
typedef vector_float2 PatternFloat2;
typedef vector_float4 PatternFloat4;
#define PATTERN_WIRE_CONSTANT static const
#endif

typedef struct PatternFrameUniforms {
    PatternFloat2 drawableSize;
    PatternFloat2 inverseDrawableSize;
} PatternFrameUniforms;

typedef struct PatternGridFrameUniforms {
    PatternFloat2 drawableSize;
    PatternFloat2 worldCenter;
    PatternFloat2 tileSize;
    float zoom;
    float gridLineWidth;
    PatternUInt32 showGridLines;
    PatternUInt32 liveVisible;
    PatternUInt32 tilingKind;
    PatternUInt32 diagnosticMode;
    PatternUInt32 compositeMode;
    PatternUInt32 padding;
} PatternGridFrameUniforms;

typedef struct PatternClipHalfPlane {
    PatternFloat2 normal;
    float offset;
    float padding;
} PatternClipHalfPlane;

typedef struct PatternProjectedStampInstance {
    PatternFloat2 canonicalXAxis;
    PatternFloat2 canonicalYAxis;
    PatternFloat2 canonicalTranslation;
    float radius;
    PatternUInt32 clipCount;
    PatternFloat4 color;
    PatternClipHalfPlane clip0;
    PatternClipHalfPlane clip1;
    PatternClipHalfPlane clip2;
    PatternClipHalfPlane clip3;
    PatternFloat4 brushAttributes;
} PatternProjectedStampInstance;

typedef struct PatternBrushMaterialUniforms {
    PatternUInt32 materialFamily;
    PatternUInt32 grainCoordinateMode;
    float strokeOpacity;
    float materialStrength;
    float wetness;
    float bleedRadius;
    PatternUInt32 softenPasses;
    float accumulationLimit;
    PatternUInt32 shapeKind;
    PatternUInt32 grainKind;
    float grainRotation;
    PatternUInt32 padding1;
} PatternBrushMaterialUniforms;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexFrameUniforms = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexGridFrameUniforms = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexDabInstances = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexBrushMaterial = 3;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexCanonical = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexLive = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexBrushShape = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexBrushGrain = 3;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexReplayLive = 4;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternMaterialWireInk = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternMaterialWireDry = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternMaterialWireGlaze = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternMaterialWireBoundedWash = 3;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternGrainCoordinateWireCanonical = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGrainCoordinateWireBrushLocal = 1;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternShapeWireHardRound = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternShapeWireSoftRound = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternShapeWireChisel = 2;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternGrainWireOpaque = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGrainWirePaper = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGrainWireNoise = 2;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireGrid = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireHalfDrop = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireBrick = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorX = 3;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorY = 4;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorXY = 5;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireRotational = 6;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternDiagnosticWireNone = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDiagnosticWireAsymmetricCoverage = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDiagnosticWireCanonicalCoordinates = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDiagnosticWireBrushLocalCoordinates = 3;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternCompositeWireDraw = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternCompositeWireErase = 1;

#undef PATTERN_WIRE_CONSTANT

#endif
