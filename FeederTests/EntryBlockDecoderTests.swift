import Foundation
import Testing

@testable import Feeder

// MARK: - decodeBlocks(data:fallbackPlainText:fallbackURL:)

@MainActor
struct EntryBlockDecoderTests {
  private let articleURL = "https://example.com/article"

  @Test
  func decodesValidJSONToOriginalBlocks() {
    let original: [ArticleBlock] = [
      .heading(level: 2, text: "Section"),
      .paragraph(text: "Hello world"),
      .blockquote(text: "Quoted"),
    ]
    guard let data = original.toJSONData() else {
      Issue.record("Failed to encode fixture blocks")
      return
    }

    let blocks = decodeBlocks(
      data: data,
      fallbackPlainText: "ignored",
      fallbackURL: articleURL
    )

    #expect(blocks == original)
  }

  @Test
  func nilDataFallsBackToPlainTextWithOpenInBrowser() {
    let blocks = decodeBlocks(
      data: nil,
      fallbackPlainText: "Body text from feed",
      fallbackURL: articleURL
    )

    #expect(blocks.count == 2)
    #expect(blocks.first == .paragraph(text: "Body text from feed"))
    if case .paragraph(let text) = blocks.last {
      #expect(text.contains("Open in browser"))
      #expect(text.contains(articleURL))
    } else {
      Issue.record("Expected trailing paragraph block")
    }
  }

  @Test
  func corruptJSONFallsBackToPlainTextWithOpenInBrowser() {
    let garbage = Data([0x00, 0x01, 0x02, 0x03])

    let blocks = decodeBlocks(
      data: garbage,
      fallbackPlainText: "Body text",
      fallbackURL: articleURL
    )

    #expect(blocks.count == 2)
    #expect(blocks.first == .paragraph(text: "Body text"))
    if case .paragraph(let text) = blocks.last {
      #expect(text.contains("Open in browser"))
      #expect(text.contains(articleURL))
    } else {
      Issue.record("Expected trailing paragraph block")
    }
  }

  @Test
  func emptyPlainTextAndNilDataReturnsMinimalFallback() {
    let blocks = decodeBlocks(
      data: nil,
      fallbackPlainText: "",
      fallbackURL: articleURL
    )

    #expect(blocks.count == 1)
    if case .paragraph(let text) = blocks.first {
      #expect(text.contains("Open in browser"))
      #expect(text.contains(articleURL))
    } else {
      Issue.record("Expected single fallback paragraph")
    }
  }

  @Test
  func emptyDecodedArrayFallsBackToPlainText() {
    guard let emptyData = ([] as [ArticleBlock]).toJSONData() else {
      Issue.record("Failed to encode empty fixture")
      return
    }

    let blocks = decodeBlocks(
      data: emptyData,
      fallbackPlainText: "Body text",
      fallbackURL: articleURL
    )

    #expect(blocks.count == 2)
    #expect(blocks.first == .paragraph(text: "Body text"))
  }
}
