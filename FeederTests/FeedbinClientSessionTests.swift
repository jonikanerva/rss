import Foundation
import Testing

@testable import Feeder

@Suite("Feedbin client session")
struct FeedbinClientSessionTests {
  @Test
  func sessionKeepsCredentialsOffDisk() {
    let configuration = FeedbinClient(username: "user@example.com", password: "fake-password").sessionConfiguration
    #expect((configuration.urlCache?.diskCapacity ?? 0) == 0)
    #expect(configuration.httpCookieStorage != nil)
    #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    #expect(configuration.urlCredentialStorage != nil)
    #expect(configuration.urlCredentialStorage !== URLCredentialStorage.shared)
    #expect(configuration.httpAdditionalHeaders == nil)
    #expect(configuration.timeoutIntervalForRequest == 60)
    #expect(configuration.timeoutIntervalForResource == 604_800)
    #expect(configuration.identifier == nil)
  }
}
