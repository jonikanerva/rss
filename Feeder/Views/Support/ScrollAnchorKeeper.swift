import AppKit
import SwiftUI
import os

/// Keeps the visible rows of the article list in place when a refresh changes
/// rows above them. Call `prepareForUpdate(from:to:)` immediately before the
/// new sections are assigned. An arm ends at the next display pass at the
/// latest. Without a probe in the window of the list, or when the table does
/// not match the section layout, the native `List` behaviour applies.
final class ScrollAnchorKeeper: NSObject {
  private struct Pending {
    weak var table: NSTableView?
    weak var clip: NSClipView?
    weak var scrollView: NSScrollView?
    let target: ScrollAnchorTarget
    var originBeforeUpdate: CGFloat
  }

  private weak var scrollView: NSScrollView?
  /// Ends an arm at the next display pass at the latest. The keeper arms only
  /// when this probe is in the window of the list.
  private weak var probe: NSView?
  private var pending: Pending?
  private var isCompensating = false

  func attach(probe: NSView, scrollView: NSScrollView) {
    self.probe = probe
    self.scrollView = scrollView
  }

  func detach(probe: NSView) {
    if self.probe === probe { self.probe = nil }
  }

  func prepareForUpdate(from oldSections: [EntryListSection], to newSections: [EntryListSection]) {
    let signpost = perfSignposter.beginInterval(PerformanceSignpostName.scrollAnchor)
    let result = arm(from: oldSections, to: newSections)
    perfSignposter.endInterval(
      PerformanceSignpostName.scrollAnchor, signpost, "phase=capture result=\(result, privacy: .public)")
  }

  func probeWillDraw() {
    if pending != nil { cancel() }
  }

  func cancel() {
    NotificationCenter.default.removeObserver(self)
    pending = nil
  }

  // MARK: - Arming

  private func arm(from oldSections: [EntryListSection], to newSections: [EntryListSection]) -> String {
    cancel()
    guard let scrollView, scrollView.window != nil, let table = scrollView.documentView as? NSTableView else {
      return "noScrollView"
    }
    guard let probe, probe.window === scrollView.window else { return "noProbe" }
    guard table.numberOfRows == EntryListTableLayout.rowCount(of: oldSections) else { return "countMismatch" }
    let clip = scrollView.contentView
    let origin = clip.bounds.origin.y
    let visible = table.rows(in: clip.documentVisibleRect)
    let visibleRows = (visible.location..<(visible.location + visible.length)).map { row in
      let rect = table.rect(ofRow: row)
      return ScrollAnchorRowFrame(tableRow: row, minY: rect.minY, maxY: rect.maxY)
    }
    let candidates = EntryListScrollAnchor.candidates(
      visibleRows: visibleRows, origin: origin, sections: oldSections)
    guard
      let target = EntryListScrollAnchor.target(
        candidates: candidates, oldSections: oldSections, newSections: newSections)
    else { return "noTarget" }
    pending = Pending(table: table, clip: clip, scrollView: scrollView, target: target, originBeforeUpdate: origin)
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(documentGeometryDidChange(_:)), name: NSView.frameDidChangeNotification,
      object: table)
    for row in visibleRows {
      guard let rowView = table.rowView(atRow: row.tableRow, makeIfNecessary: false) else { continue }
      center.addObserver(
        self, selector: #selector(documentGeometryDidChange(_:)), name: NSView.frameDidChangeNotification,
        object: rowView)
    }
    center.addObserver(
      self, selector: #selector(clipBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: clip)
    probe.needsDisplay = true
    return "armed"
  }

  // MARK: - Compensation

  @objc
  private func documentGeometryDidChange(_ notification: Notification) {
    guard let pending else { return }
    guard let table = pending.table, let clip = pending.clip, let scrollView = pending.scrollView else {
      cancel()
      return
    }
    let target = pending.target
    let rowCount = table.numberOfRows
    if rowCount == target.oldRowCount, target.oldRowCount != target.expectedRowCount { return }
    guard rowCount == target.expectedRowCount else {
      cancel()
      return
    }
    let signpost = perfSignposter.beginInterval(PerformanceSignpostName.scrollAnchor)
    let y = EntryListScrollAnchor.clipOrigin(
      newAnchorMinY: table.rect(ofRow: target.newTableRow).minY,
      oldAnchorMinY: target.oldDocumentMinY,
      originBeforeUpdate: pending.originBeforeUpdate,
      documentHeight: table.frame.height,
      viewportHeight: clip.bounds.height,
      topInset: scrollView.contentInsets.top,
      bottomInset: scrollView.contentInsets.bottom)
    let delta = y - clip.bounds.origin.y
    if abs(delta) > 0.5 {
      isCompensating = true
      clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
      scrollView.reflectScrolledClipView(clip)
      isCompensating = false
    }
    perfSignposter.endInterval(
      PerformanceSignpostName.scrollAnchor, signpost, "phase=compensate delta=\(Double(delta), privacy: .public)")
    cancel()
  }

  @objc
  private func clipBoundsDidChange(_ notification: Notification) {
    guard !isCompensating, var pending, let table = pending.table, let clip = pending.clip else { return }
    let target = pending.target
    let rowCount = table.numberOfRows
    if target.oldRowCount != target.expectedRowCount, rowCount == target.oldRowCount {
      // A scroll before the update lands: the anchor keeps its offset from the
      // new position.
      pending.originBeforeUpdate = clip.bounds.origin.y
      self.pending = pending
    } else if target.oldRowCount == target.expectedRowCount || rowCount != target.expectedRowCount {
      cancel()
    }
  }
}

struct ScrollAnchorProbe: NSViewRepresentable {
  let keeper: ScrollAnchorKeeper

  func makeNSView(context: Context) -> ScrollAnchorProbeView {
    ScrollAnchorProbeView(keeper: keeper)
  }

  func updateNSView(_ nsView: ScrollAnchorProbeView, context: Context) {}
}

/// Gives the keeper the scroll view of the list from inside a section header,
/// and ends a pending arm at the next display pass. It takes no mouse events.
final class ScrollAnchorProbeView: NSView {
  let keeper: ScrollAnchorKeeper

  init(keeper: ScrollAnchorKeeper) {
    self.keeper = keeper
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      keeper.detach(probe: self)
      return
    }
    guard let scrollView = surroundingScrollView() else { return }
    keeper.attach(probe: self, scrollView: scrollView)
  }

  override func viewWillDraw() {
    super.viewWillDraw()
    keeper.probeWillDraw()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  private func surroundingScrollView() -> NSScrollView? {
    if let enclosingScrollView { return enclosingScrollView }
    // The floating copy of a section header sits outside the clip view, so its
    // `enclosingScrollView` is nil.
    var view = superview
    while let current = view {
      if let scrollView = current as? NSScrollView { return scrollView }
      view = current.superview
    }
    return nil
  }
}
