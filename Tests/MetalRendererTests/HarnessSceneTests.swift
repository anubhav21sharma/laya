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
          "schemaVersion": 2,
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

    #expect(throws: HarnessSceneError.unsupportedSchema(2)) {
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
