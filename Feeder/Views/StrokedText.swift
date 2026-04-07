import AppKit
import SwiftUI

/// A text label that simulates bold via negative `strokeWidth` on `NSAttributedString`,
/// keeping glyph advance widths identical across bold/regular states so line-breaking
/// never shifts when toggling read/unread.
struct StrokedText: NSViewRepresentable {
  let text: String
  let size: CGFloat
  let isBold: Bool
  let color: NSColor
  let lineLimit: Int

  init(
    _ text: String,
    size: CGFloat,
    isBold: Bool,
    color: NSColor,
    lineLimit: Int = 1
  ) {
    self.text = text
    self.size = size
    self.isBold = isBold
    self.color = color
    self.lineLimit = lineLimit
  }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: "")
    field.isEditable = false
    field.isSelectable = false
    field.drawsBackground = false
    field.isBordered = false
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = lineLimit
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    field.attributedStringValue = styledString
    field.maximumNumberOfLines = lineLimit
  }

  private var styledString: NSAttributedString {
    let font = NSFont.systemFont(ofSize: size, weight: .regular)
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
    ]
    if isBold {
      attributes[.strokeWidth] = NSNumber(value: -3)
      attributes[.strokeColor] = color
    }
    return NSAttributedString(string: text, attributes: attributes)
  }
}
