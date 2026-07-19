import Foundation

public enum MetalRendererError: Error, Equatable, LocalizedError {
    case commandQueueUnavailable
    case defaultLibraryUnavailable
    case shaderFunctionUnavailable(String)
    case pipelineCreationFailed(String)
    case textureAllocationFailed
    case sharedEventUnavailable
    case instanceBufferAllocationFailed
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case commandFailed(String)
    case pendingDabCapacityExceeded(Int)

    public var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable:
            "Metal command queue creation failed."
        case .defaultLibraryUnavailable:
            "The app Metal library is unavailable."
        case let .shaderFunctionUnavailable(name):
            "Metal shader function '\(name)' is unavailable."
        case let .pipelineCreationFailed(message):
            "Metal pipeline creation failed: \(message)"
        case .textureAllocationFailed:
            "Metal render texture allocation failed."
        case .sharedEventUnavailable:
            "Metal shared-event creation failed."
        case .instanceBufferAllocationFailed:
            "Metal instance-buffer allocation failed."
        case .commandBufferUnavailable:
            "Metal command buffer creation failed."
        case .renderEncoderUnavailable:
            "Metal render encoder creation failed."
        case let .commandFailed(message):
            "Metal command execution failed: \(message)"
        case let .pendingDabCapacityExceeded(capacity):
            "Pending dab capacity \(capacity) was exceeded."
        }
    }
}
