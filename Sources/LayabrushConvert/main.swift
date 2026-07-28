import BrushConverter

@main
enum LayabrushConvertCommand {
    static func main() {
        print(
            "layabrush-convert foundation "
                + "IR-v\(ForeignBrushIR.currentSchemaVersion)"
        )
    }
}
