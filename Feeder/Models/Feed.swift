import Foundation
import SwiftData

/// Live `Feed` is whatever the latest `VersionedSchema` declares — see
/// `Entry.swift` for the rationale behind the typealias-to-latest pattern.
typealias Feed = FeederSchemaV2.Feed
