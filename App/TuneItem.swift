import Foundation
import SIDCatalog

/// View-layer wrapper around a `TuneRow` with a non-optional `Identifiable.id`.
/// `TuneRow.id` is `Int64?` because GRDB uses `nil` for "not yet inserted",
/// which makes SwiftUI Table selection types awkward. We unwrap once here.
public struct TuneItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let row: TuneRow

    public init?(row: TuneRow) {
        guard let id = row.id else { return nil }
        self.id = id
        self.row = row
    }

    public static func == (lhs: TuneItem, rhs: TuneItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
