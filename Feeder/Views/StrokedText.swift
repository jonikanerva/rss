import SwiftUI

/// A `TextRenderer` that simulates bold by drawing text multiple times with sub-pixel
/// offsets, thickening glyphs visually without changing their advance widths.
/// This keeps line-breaking identical between bold and regular states.
struct FakeBoldRenderer: TextRenderer {
  var isBold: Bool

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    if isBold {
      // Sub-pixel offset draws thicken glyphs without altering metrics
      let offset: CGFloat = 0.25
      let offsets: [(CGFloat, CGFloat)] = [(-offset, 0), (offset, 0)]
      for (dx, dy) in offsets {
        var shifted = context
        shifted.translateBy(x: dx, y: dy)
        for line in layout {
          shifted.draw(line)
        }
      }
    }
    // Always draw the base text
    for line in layout {
      context.draw(line)
    }
  }
}
