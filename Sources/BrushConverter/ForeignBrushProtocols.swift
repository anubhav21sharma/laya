import Foundation

public protocol ForeignBrushParser: Sendable {
    var identifier: String { get }

    func probe(_ source: Data) throws -> Bool
    func parse(_ source: Data) throws -> [ForeignBrushDocument]
}

public protocol ForeignBrushMapper: Sendable {
    associatedtype Output: Sendable

    func map(_ document: ForeignBrushDocument) throws -> Output
}
