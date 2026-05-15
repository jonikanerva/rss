import SwiftUI
import Testing

@testable import Feeder

// Silent-regression guard for the user-facing AppTextSize enum: locks the
// rawValue → DynamicTypeSize mapping and the `1`-based numbering that exists
// specifically to keep the `UserDefaults` zero-fallback from clobbering the
// `.medium` `@AppStorage` default. Behaviour of `.dynamicTypeSize(_:)` itself
// is exercised by the SwiftUI runtime — these tests only protect the bridge.

@MainActor
struct AppTextSizeTests {
  @Test
  func smallMapsToDynamicTypeSizeSmall() {
    #expect(AppTextSize.small.dynamicTypeSize == .small)
  }

  @Test
  func mediumMapsToDynamicTypeSizeMedium() {
    #expect(AppTextSize.medium.dynamicTypeSize == .medium)
  }

  @Test
  func largeMapsToDynamicTypeSizeLarge() {
    #expect(AppTextSize.large.dynamicTypeSize == .large)
  }

  @Test
  func xLargeMapsToDynamicTypeSizeXLarge() {
    #expect(AppTextSize.xLarge.dynamicTypeSize == .xLarge)
  }

  @Test
  func xxLargeMapsToDynamicTypeSizeXXLarge() {
    #expect(AppTextSize.xxLarge.dynamicTypeSize == .xxLarge)
  }

  @Test
  func allCasesCountIsFive() {
    #expect(AppTextSize.allCases.count == 5)
  }

  @Test
  func rawValueZeroIsNil() {
    // Documents the zero-trap escape: a missing UserDefaults integer reads
    // back as 0, so AppTextSize(rawValue: 0) must not collide with the first
    // case — otherwise the @AppStorage default of .medium would be silently
    // overridden on a fresh install.
    #expect(AppTextSize(rawValue: 0) == nil)
  }

  @Test
  func rawValueOneIsSmall() {
    #expect(AppTextSize(rawValue: 1) == .small)
  }
}
