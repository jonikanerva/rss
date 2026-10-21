import Foundation

// MARK: - Detail pane paging (pure)

nonisolated enum DetailPageDirection: Sendable, Equatable {
  case down
  case up
}

/// One page request for the detail pane. Each request has a new `sequence`,
/// so two requests in the same direction are not equal and each one scrolls.
nonisolated struct DetailPageCommand: Sendable, Equatable {
  static let initial = DetailPageCommand(sequence: 0, direction: .down)

  let sequence: Int
  let direction: DetailPageDirection

  func next(_ direction: DetailPageDirection) -> DetailPageCommand {
    DetailPageCommand(sequence: sequence &+ 1, direction: direction)
  }
}

/// The part of the viewport that one page scrolls. The rest stays on screen,
/// so the reader keeps the context of the previous page.
nonisolated let detailPageFraction: CGFloat = 0.875

/// The vertical offset after one page from `current`. The result is never
/// below the top; the scroll view clamps it at the end of the content.
nonisolated func pagedScrollOffset(
  current: CGFloat, viewportHeight: CGFloat, direction: DetailPageDirection
) -> CGFloat {
  let page = max(viewportHeight, 0) * detailPageFraction
  let target =
    switch direction {
    case .down: current + page
    case .up: current - page
    }
  return max(target, 0)
}
