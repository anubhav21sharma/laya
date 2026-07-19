#ifndef PATTERN_SHADER_TYPES_H
#define PATTERN_SHADER_TYPES_H

#ifdef __METAL_VERSION__
#include <metal_stdlib>
using namespace metal;
typedef uint PatternUInt32;
typedef float2 PatternFloat2;
#define PATTERN_WIRE_CONSTANT constant
#else
#include <stdint.h>
#include <simd/simd.h>
typedef uint32_t PatternUInt32;
typedef vector_float2 PatternFloat2;
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
} PatternGridFrameUniforms;

typedef struct PatternDabInstance {
    PatternFloat2 center;
    float radius;
    float padding;
} PatternDabInstance;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexFrameUniforms = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexGridFrameUniforms = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexDabInstances = 2;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexCanonical = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexLive = 1;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireGrid = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireHalfDrop = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireBrick = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorX = 3;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorY = 4;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorXY = 5;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireRotational = 6;

#undef PATTERN_WIRE_CONSTANT

#endif
