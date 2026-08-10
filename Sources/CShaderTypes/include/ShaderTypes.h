#ifndef PATTERN_SHADER_TYPES_H
#define PATTERN_SHADER_TYPES_H

#ifdef __METAL_VERSION__
#include <metal_stdlib>
using namespace metal;
typedef uint PatternUInt32;
typedef int PatternInt32;
typedef uint2 PatternUInt2;
typedef int2 PatternInt2;
typedef float2 PatternFloat2;
typedef float4 PatternFloat4;
typedef uint4 PatternUInt4;
#define PATTERN_WIRE_CONSTANT constant
#else
#include <stddef.h>
#include <stdint.h>
#include <simd/simd.h>
typedef uint32_t PatternUInt32;
typedef int32_t PatternInt32;
typedef vector_uint2 PatternUInt2;
typedef vector_int2 PatternInt2;
typedef vector_float2 PatternFloat2;
typedef vector_float4 PatternFloat4;
typedef vector_uint4 PatternUInt4;
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
    PatternUInt32 symmetryFamily;
    PatternFloat2 repeatSize;
    PatternFloat2 latticeXAxis;
    PatternFloat2 latticeYAxis;
    PatternFloat2 latticeTranslation;
    PatternUInt32 guideKind;
    PatternUInt32 showCanvasBoundary;
} PatternGridFrameUniforms;

typedef struct PatternRadialFrameUniforms {
    PatternFloat2 canvasSize;
    PatternFloat2 center;
    float referenceAngle;
    float sectorAngle;
    PatternUInt32 displayedSectorCount;
    PatternUInt32 dihedral;
    PatternFloat2 pageOrigin;
    PatternFloat2 pageTableSize;
    PatternUInt32 atlasColumns;
    PatternUInt32 pageSide;
    PatternFloat2 atlasSize;
} PatternRadialFrameUniforms;

typedef struct PatternClipHalfPlane {
    PatternFloat2 normal;
    float offset;
    float padding;
} PatternClipHalfPlane;

typedef struct PatternDepositionStampInstance {
    PatternFloat4 tipFrame0;
    PatternFloat4 tipFrame1;
    PatternFloat4 primaryGrainFrame0;
    PatternFloat4 primaryGrainFrame1;
    PatternFloat4 secondaryGrainFrame0;
    PatternFloat4 secondaryGrainFrame1;
    PatternFloat4 premultipliedColor;
    PatternFloat4 coverageInputs;
    PatternClipHalfPlane clip0;
    PatternClipHalfPlane clip1;
    PatternClipHalfPlane clip2;
    PatternClipHalfPlane clip3;
    PatternUInt4 identity;
    PatternUInt4 metadata;
    PatternFloat4 reserved0;
    PatternFloat4 reserved1;
} PatternDepositionStampInstance;

typedef struct PatternDepositionMaterialUniforms {
    // (primary grain strength, secondary grain strength, tip threshold,
    // accumulation limit)
    PatternFloat4 coverageParameters;
    // (secondary scale, secondary rotation, secondary offset x,
    // secondary offset y)
    PatternFloat4 secondaryShapeTransform;
    // (edge strength, reserved, reserved, reserved)
    PatternFloat4 edgeParameters;
    // (secondary shape combination, antialiasing, primary shape kind,
    // secondary shape kind)
    PatternUInt4 options;
} PatternDepositionMaterialUniforms;

#ifndef __METAL_VERSION__
static inline size_t
PatternDepositionStampInstanceOffsetTipFrame0(void) {
    return offsetof(PatternDepositionStampInstance, tipFrame0);
}

static inline size_t
PatternDepositionStampInstanceOffsetTipFrame1(void) {
    return offsetof(PatternDepositionStampInstance, tipFrame1);
}

static inline size_t
PatternDepositionStampInstanceOffsetPrimaryGrainFrame0(void) {
    return offsetof(PatternDepositionStampInstance, primaryGrainFrame0);
}

static inline size_t
PatternDepositionStampInstanceOffsetPrimaryGrainFrame1(void) {
    return offsetof(PatternDepositionStampInstance, primaryGrainFrame1);
}

static inline size_t
PatternDepositionStampInstanceOffsetSecondaryGrainFrame0(void) {
    return offsetof(PatternDepositionStampInstance, secondaryGrainFrame0);
}

static inline size_t
PatternDepositionStampInstanceOffsetSecondaryGrainFrame1(void) {
    return offsetof(PatternDepositionStampInstance, secondaryGrainFrame1);
}

static inline size_t
PatternDepositionStampInstanceOffsetPremultipliedColor(void) {
    return offsetof(PatternDepositionStampInstance, premultipliedColor);
}

static inline size_t
PatternDepositionStampInstanceOffsetCoverageInputs(void) {
    return offsetof(PatternDepositionStampInstance, coverageInputs);
}

static inline size_t
PatternDepositionStampInstanceOffsetClip0(void) {
    return offsetof(PatternDepositionStampInstance, clip0);
}

static inline size_t
PatternDepositionStampInstanceOffsetClip1(void) {
    return offsetof(PatternDepositionStampInstance, clip1);
}

static inline size_t
PatternDepositionStampInstanceOffsetClip2(void) {
    return offsetof(PatternDepositionStampInstance, clip2);
}

static inline size_t
PatternDepositionStampInstanceOffsetClip3(void) {
    return offsetof(PatternDepositionStampInstance, clip3);
}

static inline size_t
PatternDepositionStampInstanceOffsetIdentity(void) {
    return offsetof(PatternDepositionStampInstance, identity);
}

static inline size_t
PatternDepositionStampInstanceOffsetMetadata(void) {
    return offsetof(PatternDepositionStampInstance, metadata);
}

static inline size_t
PatternDepositionStampInstanceOffsetReserved0(void) {
    return offsetof(PatternDepositionStampInstance, reserved0);
}

static inline size_t
PatternDepositionStampInstanceOffsetReserved1(void) {
    return offsetof(PatternDepositionStampInstance, reserved1);
}
#endif

typedef struct PatternCompositeUniforms {
    // (stroke opacity, accumulation limit, eraser strength, reserved)
    PatternFloat4 parameters;
} PatternCompositeUniforms;

typedef struct PatternDocumentPaintMutationUniforms {
    PatternUInt2 logicalExtent;
    PatternUInt2 sourceOrigin;
    PatternUInt2 destinationOrigin;
    PatternUInt2 copyExtent;
    PatternInt2 logicalPage;
    PatternUInt2 reserved0;
    // (stroke opacity, accumulation limit, eraser strength, reserved)
    PatternFloat4 parameters;
    PatternUInt32 compositeMode;
    PatternUInt32 flags;
    PatternUInt32 sourceBytesPerRow;
    PatternUInt32 sourceByteOffset;
} PatternDocumentPaintMutationUniforms;

typedef struct PatternDocumentPaintMutationReduction {
    PatternUInt32 maximumAlphaBits;
    PatternUInt32 invalid;
} PatternDocumentPaintMutationReduction;

#ifndef __METAL_VERSION__
static inline size_t
PatternDocumentPaintMutationUniformsOffsetLogicalExtent(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, logicalExtent);
}
static inline size_t
PatternDocumentPaintMutationUniformsOffsetSourceOrigin(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, sourceOrigin);
}
static inline size_t
PatternDocumentPaintMutationUniformsOffsetDestinationOrigin(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, destinationOrigin);
}
static inline size_t
PatternDocumentPaintMutationUniformsOffsetCopyExtent(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, copyExtent);
}
static inline size_t
PatternDocumentPaintMutationUniformsOffsetLogicalPage(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, logicalPage);
}
static inline size_t
PatternDocumentPaintMutationUniformsOffsetReserved0(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, reserved0);
}
static inline size_t
PatternDocumentPaintMutationUniformsOffsetParameters(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, parameters);
}
static inline size_t
PatternDocumentPaintMutationUniformsOffsetCompositeMode(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, compositeMode);
}
static inline size_t
PatternDocumentPaintMutationUniformsOffsetFlags(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, flags);
}
static inline size_t
PatternDocumentPaintMutationUniformsOffsetSourceBytesPerRow(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, sourceBytesPerRow);
}
static inline size_t
PatternDocumentPaintMutationUniformsOffsetSourceByteOffset(void) {
    return offsetof(PatternDocumentPaintMutationUniforms, sourceByteOffset);
}
#endif

typedef struct PatternSparseSamplingUniforms {
    PatternUInt2 outputSize;
    PatternFloat2 sourceOrigin;
    PatternFloat2 sourceStep;
    PatternUInt32 descriptorCount;
    PatternUInt32 layerCount;
    PatternUInt32 bindingCount;
    PatternUInt32 addressingFlags;
    PatternUInt2 period;
    PatternUInt32 compositeMode;
    PatternUInt32 liveVisible;
    PatternUInt2 reserved;
} PatternSparseSamplingUniforms;

typedef struct PatternSparsePageTableDescriptor {
    PatternUInt32 entryOffset;
    PatternUInt32 entryCount;
    PatternInt2 tableOrigin;
    PatternUInt2 tableSize;
    PatternUInt32 layerIndex;
    PatternUInt32 role;
} PatternSparsePageTableDescriptor;

typedef struct PatternSparseTilePageEntry {
    PatternInt2 logicalOrigin;
    PatternInt2 physicalOrigin;
    PatternInt32 globalBindingSlot;
    PatternUInt32 packedLocalMinimum;
    PatternUInt32 packedLocalMaximum;
    PatternUInt32 flags;
} PatternSparseTilePageEntry;

#ifndef __METAL_VERSION__
static inline size_t PatternSparseSamplingUniformsOffsetOutputSize(void) {
    return offsetof(PatternSparseSamplingUniforms, outputSize);
}
static inline size_t PatternSparseSamplingUniformsOffsetSourceOrigin(void) {
    return offsetof(PatternSparseSamplingUniforms, sourceOrigin);
}
static inline size_t PatternSparseSamplingUniformsOffsetSourceStep(void) {
    return offsetof(PatternSparseSamplingUniforms, sourceStep);
}
static inline size_t PatternSparseSamplingUniformsOffsetDescriptorCount(void) {
    return offsetof(PatternSparseSamplingUniforms, descriptorCount);
}
static inline size_t PatternSparseSamplingUniformsOffsetLayerCount(void) {
    return offsetof(PatternSparseSamplingUniforms, layerCount);
}
static inline size_t PatternSparseSamplingUniformsOffsetBindingCount(void) {
    return offsetof(PatternSparseSamplingUniforms, bindingCount);
}
static inline size_t PatternSparseSamplingUniformsOffsetAddressingFlags(void) {
    return offsetof(PatternSparseSamplingUniforms, addressingFlags);
}
static inline size_t PatternSparseSamplingUniformsOffsetPeriod(void) {
    return offsetof(PatternSparseSamplingUniforms, period);
}
static inline size_t PatternSparseSamplingUniformsOffsetCompositeMode(void) {
    return offsetof(PatternSparseSamplingUniforms, compositeMode);
}
static inline size_t PatternSparseSamplingUniformsOffsetLiveVisible(void) {
    return offsetof(PatternSparseSamplingUniforms, liveVisible);
}
static inline size_t PatternSparseSamplingUniformsOffsetReserved(void) {
    return offsetof(PatternSparseSamplingUniforms, reserved);
}
static inline size_t PatternSparsePageTableDescriptorOffsetEntryOffset(void) {
    return offsetof(PatternSparsePageTableDescriptor, entryOffset);
}
static inline size_t PatternSparsePageTableDescriptorOffsetEntryCount(void) {
    return offsetof(PatternSparsePageTableDescriptor, entryCount);
}
static inline size_t PatternSparsePageTableDescriptorOffsetTableOrigin(void) {
    return offsetof(PatternSparsePageTableDescriptor, tableOrigin);
}
static inline size_t PatternSparsePageTableDescriptorOffsetTableSize(void) {
    return offsetof(PatternSparsePageTableDescriptor, tableSize);
}
static inline size_t PatternSparsePageTableDescriptorOffsetLayerIndex(void) {
    return offsetof(PatternSparsePageTableDescriptor, layerIndex);
}
static inline size_t PatternSparsePageTableDescriptorOffsetRole(void) {
    return offsetof(PatternSparsePageTableDescriptor, role);
}
static inline size_t PatternSparseTilePageEntryOffsetLogicalOrigin(void) {
    return offsetof(PatternSparseTilePageEntry, logicalOrigin);
}
static inline size_t PatternSparseTilePageEntryOffsetPhysicalOrigin(void) {
    return offsetof(PatternSparseTilePageEntry, physicalOrigin);
}
static inline size_t PatternSparseTilePageEntryOffsetGlobalBindingSlot(void) {
    return offsetof(PatternSparseTilePageEntry, globalBindingSlot);
}
static inline size_t PatternSparseTilePageEntryOffsetPackedLocalMinimum(void) {
    return offsetof(PatternSparseTilePageEntry, packedLocalMinimum);
}
static inline size_t PatternSparseTilePageEntryOffsetPackedLocalMaximum(void) {
    return offsetof(PatternSparseTilePageEntry, packedLocalMaximum);
}
static inline size_t PatternSparseTilePageEntryOffsetFlags(void) {
    return offsetof(PatternSparseTilePageEntry, flags);
}
#endif

PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexFrameUniforms = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexGridFrameUniforms = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexDabInstances = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexBrushMaterial = 3;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexRadialFrameUniforms = 4;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexSparseSamplingUniforms = 7;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternBufferIndexSparsePageTableDescriptors = 8;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexSparsePageEntries = 9;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexSparseBindingRemap = 10;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexSparseTextureArguments = 11;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternBufferIndexDocumentPaintMutationUniforms = 12;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternBufferIndexDocumentPaintMutationReduction = 13;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternBufferIndexDocumentPaintMutationSourceBytes = 14;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexBrushShape = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexBrushGrain = 3;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexSparseFallbackBase = 6;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexDocumentPaintBase = 22;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternTextureIndexDocumentPaintAuthoritative = 23;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternTextureIndexDocumentPaintPrediction = 24;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternTextureIndexDocumentPaintDestination = 25;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternDocumentPaintMutationABIVersion = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDocumentPaintFlagBaseKnownClear = 1;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDocumentPaintFlagAuthoritativeKnownClear = 2;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDocumentPaintFlagPredictionKnownClear = 4;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDocumentPaintFlagRadialTargetMask = 8;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternSparseMaximumFallbackTextures = 16;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternSparseMaximumTier2Textures = 512;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternSparseSamplingABIVersion = 1;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternSparseRoleCanonical = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternSparseRoleAuthoritative = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternSparseRolePrediction = 2;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternSparseAddressingPeriodic = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternSparseAddressingRadial = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternSparsePageEntryKnownClear = 1;

#ifdef __METAL_VERSION__
struct PatternSparseTextureArguments {
    array<texture2d<float>, 512> textures [[id(0)]];
};
#endif

PATTERN_WIRE_CONSTANT PatternUInt32
    PatternTextureIndexDepositionPrimaryShape = 0;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternTextureIndexDepositionSecondaryShape = 1;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternTextureIndexDepositionPrimaryGrain = 2;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternTextureIndexDepositionSecondaryGrain = 3;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternDepositionABIVersion = 2;

PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionFunctionConstantSecondaryShape = 0;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionFunctionConstantPrimaryGrain = 1;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionFunctionConstantSecondaryGrain = 2;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionFunctionConstantAccumulation = 3;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionFunctionConstantEdgeTreatment = 4;

PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionShapeCombinationReplace = 0;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionShapeCombinationMultiply = 1;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionShapeCombinationMinimum = 2;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionShapeCombinationMaximum = 3;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternDepositionShapeKindHardRound = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDepositionShapeKindTexture = 1;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternDepositionAccumulationOpaque = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDepositionAccumulationFlow = 1;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionAccumulationUniformGlaze = 2;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionAccumulationIntenseGlaze = 3;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternDepositionAccumulationDestinationOut = 4;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternDepositionEdgeNone = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDepositionEdgeDryBreakup = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDepositionEdgeMarkerOverlap = 2;

PATTERN_WIRE_CONSTANT PatternUInt32
    PatternSymmetryFamilyWireRectangular = 0;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternSymmetryFamilyWireTriangular = 1;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternSymmetryFamilyWireRadial = 2;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireGrid = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireHalfDrop = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireBrick = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorX = 3;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorY = 4;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorXY = 5;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireRotational = 6;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireSquareRotation = 7;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireSquareKaleidoscope = 8;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireHexagons = 9;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireRotation3 = 10;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireRotation6 = 11;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireKaleidoscope60 = 12;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireKaleidoscope30 = 13;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWirePlainCanvas = 14;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireRadialMirror = 15;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireRadialRotation = 16;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireRadialMandala = 17;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireRectangular = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireSquareRotation = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireSquareKaleidoscope = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireHexagons = 3;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireTriangularRotation3 = 4;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireTriangularRotation6 = 5;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireTriangularKaleidoscope60 = 6;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireTriangularKaleidoscope30 = 7;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireFinitePlain = 8;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireRadialRotation = 9;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireRadialMirror = 10;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternGuideWireRadialMandala = 11;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternDiagnosticWireNone = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDiagnosticWireAsymmetricCoverage = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDiagnosticWireCanonicalCoordinates = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternDiagnosticWireBrushLocalCoordinates = 3;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternCompositeWireDraw = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternCompositeWireErase = 1;

#undef PATTERN_WIRE_CONSTANT

#endif
