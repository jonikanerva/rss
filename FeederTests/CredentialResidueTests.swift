import Foundation
import Testing

@testable import Feeder

/// No test here may touch `URLCache.shared`: the test host is the Feeder app,
/// so the shared cache is the user's real cache.
@Suite("Credential residue")
struct CredentialResidueTests {
  // With `directory: nil` the cache can use the directory of `URLCache.shared`.
  // Give each cache its own directory.
  private static func withPrivateCache(_ body: (URLCache) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "CredentialResidueTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, directory: directory))
  }

  private static func imageURL() throws -> URL {
    try #require(URL(string: "https://images.example.com/article.jpg"))
  }

  private static func store(_ url: URL, authorization: String?, in cache: URLCache) throws {
    var request = URLRequest(url: url)
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
    let cached = CachedURLResponse(response: response, data: Data("{}".utf8), userInfo: nil, storagePolicy: .allowedInMemoryOnly)
    cache.storeCachedResponse(cached, for: request)
    try #require(isCached(url, in: cache), "a lookup without headers finds the stored response")
  }

  private static func isCached(_ url: URL, in cache: URLCache) -> Bool {
    cache.cachedResponse(for: URLRequest(url: url)) != nil
  }

  @Test(arguments: CredentialResidue.probeURLs)
  func probeHitRemovesEveryResponse(probe: URL) throws {
    try Self.withPrivateCache { cache in
      let image = try Self.imageURL()
      try Self.store(probe, authorization: "Basic ZmFrZTpmYWtl", in: cache)
      try Self.store(image, authorization: nil, in: cache)
      #expect(CredentialResidue.remove(from: cache))
      #expect(!Self.isCached(probe, in: cache))
      #expect(!Self.isCached(image, in: cache))
      #expect(!CredentialResidue.remove(from: cache), "a second call finds nothing")
    }
  }

  @Test
  func noProbeHitKeepsImages() throws {
    try Self.withPrivateCache { cache in
      let image = try Self.imageURL()
      try Self.store(image, authorization: nil, in: cache)
      #expect(!CredentialResidue.remove(from: cache))
      #expect(Self.isCached(image, in: cache))
    }
  }
}
