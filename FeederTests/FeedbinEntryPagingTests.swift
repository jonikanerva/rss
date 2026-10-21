import Foundation
import Testing

@testable import Feeder

/// A fast stub producer answers each page request at once. The consumer reads
/// slowly, so a prefetching stream would request pages ahead of it.
private actor PagedEntriesServer {
  private(set) var requestedPages: [Int] = []
  private let pageCount: Int
  private let failingPage: Int?
  private let heldPage: (page: Int, gate: AsyncGate)?

  init(pageCount: Int, failingPage: Int? = nil, heldPage: (page: Int, gate: AsyncGate)? = nil) {
    self.pageCount = pageCount
    self.failingPage = failingPage
    self.heldPage = heldPage
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let page = try #require(items.first { $0.name == "page" }?.value.flatMap(Int.init))
    requestedPages.append(page)
    if let heldPage, heldPage.page == page {
      await heldPage.gate.wait()
      if Task.isCancelled { throw URLError(.cancelled) }
    }
    let status = page == failingPage ? 500 : 200
    var headers = ["X-Feedbin-Record-Count": "\(pageCount)"]
    if page < pageCount { headers["Links"] = "<https://api.feedbin.com/v2/entries.json?page=\(page + 1)>; rel=\"next\"" }
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    let body = """
      [{"id": \(page), "feed_id": 1, "url": "https://example.com/\(page)",
        "published": "2026-10-01T00:00:00.000000Z", "created_at": "2026-10-01T00:00:00.000000Z"}]
      """
    return (Data(body.utf8), response)
  }
}

@Suite("Feedbin entry paging")
struct FeedbinEntryPagingTests {
  private func client(_ server: PagedEntriesServer) -> FeedbinClient {
    FeedbinClient(username: "user@example.com", password: "fake-password") { try await server.send($0) }
  }

  @Test
  func pageRequestStartsOnlyWhenTheConsumerAsks() async throws {
    let server = PagedEntriesServer(pageCount: 3)
    var pages = client(server).fetchAllEntryPages(since: nil).makeAsyncIterator()

    let first = try await pages.next()
    try await Task.sleep(for: .milliseconds(50))
    #expect(await server.requestedPages == [1])

    let second = try await pages.next()
    #expect(await server.requestedPages == [1, 2])
    let third = try await pages.next()
    let end = try await pages.next()

    #expect([first, second, third].map { $0?.entries.map(\.id) } == [[1], [2], [3]])
    #expect(end == nil)
    #expect(await server.requestedPages == [1, 2, 3])
  }

  @Test
  func failedPageEndsTheSequenceWithTheError() async throws {
    let server = PagedEntriesServer(pageCount: 3, failingPage: 2)
    var received: [Int] = []

    await #expect(throws: FeedbinError.self) {
      for try await page in client(server).fetchAllEntryPages(since: nil) {
        received += page.entries.map(\.id)
      }
    }

    #expect(received == [1])
    #expect(await server.requestedPages == [1, 2])
  }

  @Test
  func cancelledConsumerStopsThePaging() async throws {
    let gate = AsyncGate()
    defer { gate.open() }
    let server = PagedEntriesServer(pageCount: 3, heldPage: (2, gate))
    let pages = client(server).fetchAllEntryPages(since: nil)
    let consumer = Task {
      var received: [Int] = []
      do {
        for try await page in pages { received += page.entries.map(\.id) }
      } catch {}
      return received
    }
    try await waitUntil("the second page request waits") { await server.requestedPages == [1, 2] }

    consumer.cancel()
    gate.open()
    let received = await consumer.value

    #expect(received == [1])
    #expect(await server.requestedPages == [1, 2])
  }
}
