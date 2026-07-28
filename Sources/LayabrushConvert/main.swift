import BrushConverter
import Darwin
import Foundation

@main
enum LayabrushConvertCommand {
    static func main() {
        let output = LayabrushConvertCommandRunner.run(
            arguments: Array(CommandLine.arguments.dropFirst())
        )
        FileHandle.standardOutput.write(Data(output.standardOutput.utf8))
        FileHandle.standardError.write(Data(output.standardError.utf8))
        exit(output.exitStatus)
    }
}
