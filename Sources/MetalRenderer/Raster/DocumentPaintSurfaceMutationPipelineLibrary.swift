import Metal

enum DocumentPaintSurfaceMutationPipelineError:
    Error, Equatable, Sendable
{
    case libraryUnavailable
    case functionUnavailable(String)
    case pipelineCreationFailed(String)
}

@MainActor
struct DocumentPaintSurfaceMutationPipelineBinding {
    let stroke: any MTLComputePipelineState
    let resize: any MTLComputePipelineState
    let encodedImport: any MTLComputePipelineState
}

@MainActor
enum DocumentPaintSurfaceMutationPipelineLibrary {
    static func prepare(
        device: any MTLDevice,
        library: (any MTLLibrary)?
    ) throws -> DocumentPaintSurfaceMutationPipelineBinding {
        guard let library else {
            throw DocumentPaintSurfaceMutationPipelineError.libraryUnavailable
        }
        return DocumentPaintSurfaceMutationPipelineBinding(
            stroke: try make(
                "patternDocumentPaintStrokeMutation",
                device: device,
                library: library
            ),
            resize: try make(
                "patternDocumentPaintResizeMutation",
                device: device,
                library: library
            ),
            encodedImport: try make(
                "patternDocumentPaintEncodedImportMutation",
                device: device,
                library: library
            )
        )
    }

    private static func make(
        _ name: String,
        device: any MTLDevice,
        library: any MTLLibrary
    ) throws -> any MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw DocumentPaintSurfaceMutationPipelineError
                .functionUnavailable(name)
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw DocumentPaintSurfaceMutationPipelineError
                .pipelineCreationFailed(error.localizedDescription)
        }
    }
}
