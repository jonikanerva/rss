import Foundation
import SwiftData

/// The live `Feed` is whatever the latest `VersionedSchema` declares. See
/// `Entry.swift` for the typealias-to-latest pattern.
typealias Feed = FeederSchemaV2.Feed
