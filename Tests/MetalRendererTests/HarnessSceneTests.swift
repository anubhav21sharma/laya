import Foundation
import MetalRenderer
import Testing

@Test
func harnessSceneDecodesAndValidates() throws {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "blank-canvas",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 32,
              "y": 32,
              "expectedBGRA": [241, 244, 242, 255],
              "tolerance": 1
            }
          ]
        }
        """.utf8
    )

    let scene = try HarnessScene.decode(data)

    #expect(scene.name == "blank-canvas")
    #expect(scene.width == 64)
    #expect(scene.height == 64)
    #expect(scene.checks.count == 1)
    #expect(scene.checks[0].expectedBGRA == [241, 244, 242, 255])
}

@Test
func harnessSceneRejectsAnUnknownSchema() {
    let data = Data(
        """
        {
          "schemaVersion": 3,
          "name": "future-scene",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 0,
              "y": 0,
              "expectedBGRA": [0, 0, 0, 255],
              "tolerance": 0
            }
          ]
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.unsupportedSchema(3)) {
        try HarnessScene.decode(data)
    }
}

@Test
func harnessSceneRejectsAnOutOfBoundsPixelCheck() {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "bad-coordinate",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 64,
              "y": 0,
              "expectedBGRA": [0, 0, 0, 255],
              "tolerance": 0
            }
          ]
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.invalidCheckCoordinate(x: 64, y: 0)) {
        try HarnessScene.decode(data)
    }
}

@Test
func gridHarnessSceneDecodesVersionTwoProgramAndAssertions() throws {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "grid-interior",
          "width": 512,
          "height": 512,
          "program": "gridInterior",
          "checks": [
            {
              "channel": "liveScreen",
              "x": 200,
              "y": 256,
              "expectedBGRA": [0, 0, 0, 255],
              "tolerance": 1
            }
          ],
          "structuralChecks": [
            {
              "metric": "restampedInstanceCount",
              "relation": "equal",
              "value": 0
            }
          ]
        }
        """.utf8
    )

    let scene = try HarnessScene.decode(data)

    #expect(scene.program == .gridInterior)
    #expect(scene.checks[0].channel == .liveScreen)
    #expect(scene.structuralChecks.count == 1)
}

@Test
func schemaOneBlankSceneRemainsDecodable() throws {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "blank-canvas",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 32,
              "y": 32,
              "expectedBGRA": [241, 244, 242, 255],
              "tolerance": 1
            }
          ]
        }
        """.utf8
    )

    let scene = try HarnessScene.decode(data)
    #expect(scene.program == nil)
    #expect(scene.checks[0].channel == .screen)
}

@Test
func schemaTwoRequiresAGridProgram() {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "missing-program",
          "width": 512,
          "height": 512,
          "checks": []
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.missingProgram) {
        try HarnessScene.decode(data)
    }
}

@Test
func schemaOneForbidsGridPrograms() {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "invalid-legacy-grid",
          "width": 64,
          "height": 64,
          "program": "gridInterior",
          "checks": [
            {
              "x": 0,
              "y": 0,
              "expectedBGRA": [241, 244, 242, 255],
              "tolerance": 1
            }
          ]
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.programForbiddenForSchemaOne) {
        try HarnessScene.decode(data)
    }
}

@Test
func schemaTwoRequiresAtLeastOneAssertion() {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "missing-assertions",
          "width": 512,
          "height": 512,
          "program": "gridInterior",
          "checks": [],
          "structuralChecks": []
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.missingAssertions) {
        try HarnessScene.decode(data)
    }
}

@Test
func structuralAssertionsRejectNegativeValues() {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "negative-structural-value",
          "width": 512,
          "height": 512,
          "program": "longStroke",
          "checks": [],
          "structuralChecks": [
            {
              "metric": "missedFrameCount",
              "relation": "lessThanOrEqual",
              "value": -1
            }
          ]
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.invalidStructuralValue(-1)) {
        try HarnessScene.decode(data)
    }
}
