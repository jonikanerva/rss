import SwiftUI
import Testing

@testable import Feeder

/// Space and Shift-Space in the article list page the detail pane.
@MainActor
struct DetailPagingTests {
  @Test
  func spacePagesDownAndShiftSpacePagesUp() {
    #expect(detailPageDirection(hasSelectedEntry: true, modifiers: []) == .down)
    #expect(detailPageDirection(hasSelectedEntry: true, modifiers: .shift) == .up)
    #expect(detailPageDirection(hasSelectedEntry: true, modifiers: .capsLock) == .down)
  }

  /// Without an article the key goes on to the list.
  @Test
  func noSelectedArticleIsNotAPageKey() {
    #expect(detailPageDirection(hasSelectedEntry: false, modifiers: []) == nil)
    #expect(detailPageDirection(hasSelectedEntry: false, modifiers: .shift) == nil)
  }

  @Test
  func otherModifiersAreNotAPageKey() {
    for modifiers: EventModifiers in [.command, .option, .control, [.shift, .option]] {
      #expect(detailPageDirection(hasSelectedEntry: true, modifiers: modifiers) == nil)
    }
  }

  /// `.onChange` sees each request, also two in the same direction.
  @Test
  func eachCommandDiffersFromThePreviousOne() {
    let first = DetailPageCommand.initial.next(.down)
    let second = first.next(.down)
    #expect(first != DetailPageCommand.initial)
    #expect(second != first)
    #expect(second.direction == .down)
    #expect(second.next(.up).direction == .up)
  }

  @Test
  func pageMovesByMostOfTheViewport() {
    #expect(pagedScrollOffset(current: 100, viewportHeight: 400, direction: .down) == 450)
    #expect(pagedScrollOffset(current: 450, viewportHeight: 400, direction: .up) == 100)
  }

  @Test
  func pageUpStopsAtTheTop() {
    #expect(pagedScrollOffset(current: 120, viewportHeight: 400, direction: .up) == 0)
    #expect(pagedScrollOffset(current: -20, viewportHeight: 400, direction: .up) == 0)
  }
}
