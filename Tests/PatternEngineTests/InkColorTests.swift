import PatternEngine
import Testing

@Test
func inkColorRejectsNonfiniteAndOutOfRangeComponents() {
    #expect(InkColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8) != nil)
    #expect(InkColor(red: -.infinity, green: 0, blue: 0, alpha: 1) == nil)
    #expect(InkColor(red: 1.01, green: 0, blue: 0, alpha: 1) == nil)
}
