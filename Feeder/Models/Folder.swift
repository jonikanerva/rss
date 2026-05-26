import Foundation
import SwiftData

/// Live `Folder` is whatever the latest `VersionedSchema` declares — see
/// `Entry.swift` for the rationale behind the typealias-to-latest pattern.
typealias Folder = FeederSchemaV2.Folder
