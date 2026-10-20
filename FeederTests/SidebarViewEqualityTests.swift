import SwiftUI
import Testing

@testable import Feeder

/// `SidebarView.==` decides when `EquatableView` skips the sidebar body, so it
/// must see every input that the rows read.
@MainActor
@Suite("SidebarView equality")
struct SidebarViewEqualityTests {
  private func sidebar(
    allArticlesUnreadCount: Int = 3,
    canMarkAllRead: Bool = true,
    onMarkAllRead: @escaping (SidebarSelection) -> Void = { _ in }
  ) -> SidebarView {
    SidebarView(
      allArticlesUnreadCount: allArticlesUnreadCount,
      visibleFolderGroups: [
        SidebarFolderGroup(
          label: "tech", displayName: "Technology",
          categories: [SidebarCategorySnapshot(label: "apple", displayName: "Apple")])
      ],
      rootCategories: [SidebarCategorySnapshot(label: "world", displayName: "World")],
      categoryUnreadCounts: ["apple": 2, "world": 1],
      folderUnreadCounts: ["tech": 2],
      fontBody: .body,
      canMarkAllRead: canMarkAllRead,
      onMarkAllRead: onMarkAllRead,
      selection: .constant(.category("apple")),
      collapsedFolders: .constant(SidebarCollapsedFolders())
    )
  }

  @Test("a change of the All Articles count alone makes the views unequal")
  func allArticlesCountChangeIsUnequal() {
    #expect(sidebar(allArticlesUnreadCount: 3) != sidebar(allArticlesUnreadCount: 4))
  }

  @Test("a change of canMarkAllRead alone makes the views unequal")
  func canMarkAllReadChangeIsUnequal() {
    #expect(sidebar(canMarkAllRead: true) != sidebar(canMarkAllRead: false))
  }

  @Test("a different onMarkAllRead closure alone keeps the views equal")
  func closureChangeKeepsViewsEqual() {
    #expect(sidebar(onMarkAllRead: { _ in }) == sidebar(onMarkAllRead: { _ in }))
  }
}
