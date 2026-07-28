import BrushFormat
import Foundation

public struct ForeignBrushDocument: Equatable, Sendable {
    public let ir: ForeignBrushIR
    public let resourceData: [String: Data]

    public init(
        ir: ForeignBrushIR,
        resourceData: [String: Data]
    ) throws {
        let expected = Set(ir.resources.map(\.id))
        let actual = Set(resourceData.keys)
        guard expected == actual else {
            throw ForeignBrushValidationError.resourceTableMismatch(
                missing: expected.subtracting(actual).sorted(),
                unexpected: actual.subtracting(expected).sorted()
            )
        }

        var cumulativeBytes = 0
        for resource in ir.resources {
            guard let data = resourceData[resource.id] else {
                throw ForeignBrushValidationError.resourceTableMismatch(
                    missing: [resource.id],
                    unexpected: []
                )
            }
            guard data.count == resource.encodedByteCount else {
                throw ForeignBrushValidationError
                    .resourceByteCountMismatch(
                        resourceID: resource.id,
                        expected: resource.encodedByteCount,
                        actual: data.count
                    )
            }
            guard Self.contentSHA256(data) == resource.contentSHA256 else {
                throw ForeignBrushValidationError.resourceHashMismatch(
                    resource.id
                )
            }
            let (next, overflow) = cumulativeBytes.addingReportingOverflow(
                data.count
            )
            guard !overflow,
                  next <= ForeignBrushLimits.maximumCumulativeResourceBytes
            else {
                throw ForeignBrushValidationError
                    .cumulativeResourceBytesExceeded(
                        maximum:
                            ForeignBrushLimits.maximumCumulativeResourceBytes
                    )
            }
            cumulativeBytes = next
        }

        self.ir = ir
        self.resourceData = resourceData
    }

    public static func contentSHA256(_ data: Data) -> String {
        BrushContentHash.sha256Hex(of: data)
    }

}
