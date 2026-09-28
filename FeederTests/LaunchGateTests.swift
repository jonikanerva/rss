import Foundation
import Testing

@testable import Feeder

/// Pins the launch-mode table: which data store, credential store, and
/// account phase each launch environment gets. No test here may call the
/// production engine's account methods: its store is the owner's real Keychain.
@MainActor
@Suite("Launch gates")
struct LaunchGateTests {
  // MARK: - In-memory store gate

  @Test(arguments: [
    ["FEEDER_HEADLESS": "1"]
  ])
  func inMemoryStoresServeTestLaunches(environment: [String: String]) {
    #expect(FeederApp.usesInMemoryStores(in: environment))
  }

  @Test(arguments: [
    [:],
    ["FEEDER_HEADLESS": "0"],
    ["XCODE_RUNNING_FOR_PREVIEWS": "1"],
    ["XCTestConfigurationFilePath": "/x"],
  ])
  func everyOtherLaunchKeepsTheOnDiskStores(environment: [String: String]) {
    #expect(!FeederApp.usesInMemoryStores(in: environment))
  }

  // MARK: - Feedbin account gate

  @Test(arguments: [
    ["FEEDER_HEADLESS": "1"],
    ["XCODE_RUNNING_FOR_PREVIEWS": "1"],
  ])
  func headlessAndPreviewsUseNoAccount(environment: [String: String]) {
    #expect(!FeederApp.usesFeedbinAccount(in: environment))
  }

  @Test(arguments: [
    [:],
    ["FEEDER_HEADLESS": "0"],
    ["XCTestConfigurationFilePath": "/x"],
  ])
  func everyOtherLaunchUsesAnAccount(environment: [String: String]) {
    #expect(FeederApp.usesFeedbinAccount(in: environment))
  }

  // MARK: - One engine per launch mode

  @Test
  func productionLaunchChecksTheKeychainAccount() {
    let engine = FeederApp.makeSyncEngine(environment: [:])
    #expect(engine.credentialStore is KeychainFeedbinCredentialStore)
    #expect(engine.account == .checking)
  }

  @Test
  func headlessLaunchNeverUsesAnAccount() {
    let engine = FeederApp.makeSyncEngine(environment: ["FEEDER_HEADLESS": "1"])
    #expect(engine.credentialStore is MemoryFeedbinCredentialStore)
    #expect(engine.account == .unused)
  }

  @Test
  func previewEnginesNeverUseTheKeychain() {
    #expect(FeederApp.makeSyncEngine(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]).account == .unused)

    let preview = SyncEngine.preview()
    #expect(preview.credentialStore is MemoryFeedbinCredentialStore)
    #expect(preview.account == .unused)
    #expect(SyncEngine.preview(account: .noAccount).account == .noAccount)
  }
}
