import BrushFormat

public enum ForeignBrushMappingResultError: Error, Equatable, Sendable {
    case missingConversionReport
    case conversionReportMismatch
}

/// A mapped brush is observable only after native package validation succeeds.
public struct ForeignBrushMappingResult: Equatable, Sendable {
    public let package: BrushPackage
    public let report: BrushConversionReport

    public init(package: BrushPackage) throws {
        guard let report = package.conversionReport else {
            throw ForeignBrushMappingResultError.missingConversionReport
        }
        self.package = package
        self.report = report
    }

    public init(
        package: BrushPackage,
        report: BrushConversionReport
    ) throws {
        guard package.conversionReport == report else {
            throw ForeignBrushMappingResultError.conversionReportMismatch
        }
        self.package = package
        self.report = report
    }
}
