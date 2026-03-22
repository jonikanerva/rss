import Foundation

/// A structured block representing one semantic unit of article content.
/// Produced by parsing HTML at persist time, consumed by SwiftUI at display time.
enum ArticleBlock: Codable, Sendable {
    case paragraph(text: String)
    case heading(level: Int, text: String)
    case image(url: String, alt: String)
    case codeBlock(code: String)
    case list(ordered: Bool, items: [String])
    case blockquote(text: String)
    case divider
}

extension [ArticleBlock] {
    /// Plain text extracted from blocks for classification and search.
    nonisolated var classificationText: String {
        compactMap { block in
            switch block {
            case .paragraph(let text), .heading(_, let text),
                 .blockquote(let text):
                return text
            case .list(_, let items):
                return items.joined(separator: " ")
            case .codeBlock(let code):
                return code
            case .image, .divider:
                return nil
            }
        }.joined(separator: "\n")
    }
}

// MARK: - JSON encoding/decoding helpers

extension [ArticleBlock] {
    nonisolated func toJSONData() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

extension Data {
    nonisolated func toArticleBlocks() -> [ArticleBlock]? {
        try? JSONDecoder().decode([ArticleBlock].self, from: self)
    }
}
