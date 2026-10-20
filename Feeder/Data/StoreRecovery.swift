import Foundation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.feeder.app", category: "StoreRecovery")

// MARK: - Launch phase

/// The launch state of the app store. A failure keeps every store file.
enum StorePhase {
  case ready(ModelContainer)
  case failed(StoreFailure)
}

/// Why the recovery view shows. `detail` is the system error text.
enum StoreFailure: Equatable {
  /// The open failed. No store file and no defaults key changed.
  case openFailed(detail: String)
  /// Start Over stopped before a new store opened. No store file was deleted.
  case startOverFailed(detail: String)
}

// MARK: - File access

/// The file operations that Start Over uses. Tests inject a failing `moveItem`.
struct StoreFileSystem {
  var fileExists: (URL) -> Bool
  var createDirectory: (URL) throws -> Void
  var moveItem: (URL, URL) throws -> Void

  static var live: StoreFileSystem {
    StoreFileSystem(
      fileExists: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) },
      createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) },
      moveItem: { try FileManager.default.moveItem(at: $0, to: $1) }
    )
  }
}

enum StoreBackupError: Error, Equatable {
  case folderNotCreated(detail: String)
  /// `restored` is false when a file that moved before the failure did not
  /// move back. The backup folder then holds that file.
  case moveFailed(fileName: String, detail: String, restored: Bool)
}

// MARK: - Recovery

/// Opens the app store and runs Start Over. No function here deletes a file.
enum StoreRecovery {
  /// An in-memory failure throws. An on-disk failure returns `.failed` and
  /// changes no file and no defaults key.
  static func openStore(isStoredInMemoryOnly: Bool, open: () throws -> ModelContainer) throws -> StorePhase {
    do {
      return .ready(try open())
    } catch {
      guard !isStoredInMemoryOnly else { throw error }
      logger.error("Store open failed. The store files stay unchanged: \(String(describing: error), privacy: .private)")
      return .failed(.openFailed(detail: error.localizedDescription))
    }
  }

  /// Remove the sync keys, move the store files into a new backup folder next
  /// to the store, then open a new store. Pending reads stay queued. The keys go
  /// first: a stop after the move must not leave a new store with the seeded
  /// flag set, because the bootstrap then skips the default taxonomy.
  static func startOver(
    storeURL: URL,
    backupFolderName: String,
    defaults: UserDefaults,
    fileSystem: StoreFileSystem,
    open: () throws -> ModelContainer
  ) -> StorePhase {
    defaults.removeObject(forKey: lastSyncDateUserDefaultsKey)
    defaults.removeObject(forKey: defaultsSeededUserDefaultsKey)
    let backupFolder = storeURL.deletingLastPathComponent().appending(path: backupFolderName, directoryHint: .isDirectory)
    do {
      try moveStoreFiles(of: storeURL, into: backupFolder, fileSystem: fileSystem)
    } catch {
      logger.error("Start Over stopped. No store file was deleted: \(String(describing: error), privacy: .private)")
      return .failed(.startOverFailed(detail: message(for: error)))
    }
    logger.notice("Start Over moved the store files to \(backupFolder.path(percentEncoded: false), privacy: .private)")
    do {
      return .ready(try open())
    } catch {
      logger.error("Store open after Start Over failed: \(String(describing: error), privacy: .private)")
      return .failed(.startOverFailed(detail: error.localizedDescription))
    }
  }

  /// Move the store file and its two SQLite sidecars. A missing file is not a
  /// failure. The first failed move stops the backup and moves the earlier
  /// files back, so the store files stay together.
  static func moveStoreFiles(of storeURL: URL, into backupFolder: URL, fileSystem: StoreFileSystem) throws(StoreBackupError) {
    do {
      try fileSystem.createDirectory(backupFolder)
    } catch {
      throw .folderNotCreated(detail: error.localizedDescription)
    }
    var moved: [(source: URL, destination: URL)] = []
    for source in storeFileURLs(of: storeURL) where fileSystem.fileExists(source) {
      let destination = backupFolder.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
      do {
        try fileSystem.moveItem(source, destination)
        moved.append((source, destination))
      } catch {
        let restored = moveBack(moved, fileSystem: fileSystem)
        throw .moveFailed(fileName: source.lastPathComponent, detail: error.localizedDescription, restored: restored)
      }
    }
  }

  /// `Feeder.store`, `Feeder.store-shm`, and `Feeder.store-wal`.
  static func storeFileURLs(of storeURL: URL) -> [URL] {
    let folder = storeURL.deletingLastPathComponent()
    let name = storeURL.lastPathComponent
    return [name, name + "-shm", name + "-wal"].map { folder.appending(path: $0, directoryHint: .notDirectory) }
  }

  /// A UTC timestamp keeps the names in time order. `id` makes each name unique.
  static func backupFolderName(at date: Date, id: UUID) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .gmt
    formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
    return "Feeder Store Backup \(formatter.string(from: date)) \(id.uuidString.prefix(8))"
  }

  private static func moveBack(_ moved: [(source: URL, destination: URL)], fileSystem: StoreFileSystem) -> Bool {
    var restored = true
    for file in moved.reversed() {
      do {
        try fileSystem.moveItem(file.destination, file.source)
      } catch {
        logger.error("A store file did not move back: \(String(describing: error), privacy: .private)")
        restored = false
      }
    }
    return restored
  }

  private static func message(for error: StoreBackupError) -> String {
    switch error {
    case .folderNotCreated(let detail):
      "Feeder could not create the backup folder. \(detail)"
    case .moveFailed(let fileName, let detail, restored: true):
      "Feeder could not move \(fileName) to the backup folder. The database files are in their original place. \(detail)"
    case .moveFailed(let fileName, let detail, restored: false):
      "Feeder could not move \(fileName) to the backup folder. Some database files are in the backup folder. \(detail)"
    }
  }
}
