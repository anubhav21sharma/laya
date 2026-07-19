import EditorCore
import Testing

@Test
func editorCoreModuleIdentityIsStable() {
    #expect(EditorCoreInfo.moduleName == "EditorCore")
}
