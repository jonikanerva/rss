import Foundation

/// The writer and the read-only reader of one store. `FeederApp` builds both
/// on the same container after the bootstrap and passes them to the window.
nonisolated struct StoreActors: Sendable {
  let writer: DataWriter
  let reader: DataReader
}
