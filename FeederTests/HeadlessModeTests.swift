import SwiftData
import Testing

@testable import Feeder

// MARK: - Headless mode (#141)

/// The mandated always-run assurance for the headless credential bypass. It runs
/// on every `make test-all` (which sets `FEEDER_HEADLESS=1` on the host) and is
/// designed to FAIL-CLOSED: a future edit that puts a real credential read, a
/// real Feedbin client, or a re-introduced OS-settable auto-detect on the
/// headless path flips one of these assertions.
@Suite("Headless mode")
@MainActor
struct HeadlessModeTests {
  // MARK: - Gate: FEEDER_HEADLESS only, both directions

  /// The trigger is exactly one explicit env var. Both directions are asserted
  /// against an injected environment (no dependence on the ambient process env),
  /// and crucially `XCTestConfigurationFilePath` alone does NOT enable headless —
  /// guarding against re-introducing the OS-settable auto-detect that was cut.
  @Test("Gate reads FEEDER_HEADLESS only — both directions")
  func gateReadsFeederHeadlessOnly() {
    #expect(HeadlessMode.isEnabled(in: ["FEEDER_HEADLESS": "1"]))
    #expect(!HeadlessMode.isEnabled(in: [:]))
    #expect(!HeadlessMode.isEnabled(in: ["FEEDER_HEADLESS": "0"]))
    #expect(!HeadlessMode.isEnabled(in: ["XCTestConfigurationFilePath": "/x"]))
  }

  // MARK: - Store gate fires together with the credential-skip

  /// Under `FEEDER_HEADLESS=1` the store gate MUST yield an in-memory container —
  /// the load-bearing invariant that the headless credential-skip can never run
  /// against the real on-disk store. `FeederApp.init` and the credential-skip in
  /// `ContentView.checkCredentials` read the SAME `HeadlessMode.isEnabled`
  /// (grep-enforced in review), so they fire together. `make test-all` sets the
  /// flag, so this runs there; a bare Cmd-U without the scheme flag skips it (the
  /// pure-core test above still covers the gate logic).
  @Test(
    "Under FEEDER_HEADLESS the store gate yields an in-memory container",
    .enabled(if: HeadlessMode.isEnabled))
  func headlessForcesInMemoryStore() {
    let app = FeederApp()
    #expect(app.modelContainer.configurations.first?.isStoredInMemoryOnly == true)
  }

  // MARK: - Seam 2: classification never reaches a real backend

  /// The headless provider assigns the explicit fallback category with zero
  /// confidence and reaches no backend — so an automated launch keeps the
  /// `VISION.md` "every article gets exactly one main category" invariant without
  /// ever performing the OpenAI-key Keychain read.
  @Test("Headless provider assigns the fallback category, no backend")
  func headlessProviderAssignsFallback() async throws {
    let provider = HeadlessClassificationProvider()
    #expect(await provider.isAvailable)

    let result = try await provider.classify(
      title: "Anything", body: "Anything", url: "https://example.com", instructions: "")
    #expect(result.category == uncategorizedLabel)
    #expect(result.confidence == 0)
  }

  // MARK: - Seam 1: the sync client can never reach the network

  /// The inert client performs no I/O and returns empties, so a headless launch
  /// that (defensively) attaches it can never contact Feedbin.
  @Test("Inert Feedbin client performs no I/O and returns empties")
  func inertClientReturnsEmpties() async throws {
    let client = InertFeedbinClient()
    let subscriptions = try await client.fetchSubscriptions()
    let icons = try await client.fetchIcons()
    let unreadIDs = try await client.fetchUnreadEntryIDs()
    let extracted = try await client.fetchExtractedContent(from: "https://example.com")
    #expect(subscriptions.isEmpty)
    #expect(icons.isEmpty)
    #expect(unreadIDs.isEmpty)
    #expect(extracted == nil)

    var pageCount = 0
    for try await _ in client.fetchAllEntryPages(since: nil) { pageCount += 1 }
    #expect(pageCount == 0)
  }
}
