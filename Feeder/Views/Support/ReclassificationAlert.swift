import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.feeder.app", category: "ReclassificationAlert")

extension View {
  /// Shows the reclassification confirmation as an `NSAlert` sheet on the window
  /// of this view while `target` is not nil. `onDismiss` runs when the alert
  /// closes, before `onReclassify`.
  func reclassificationAlert(
    target: String?, onReclassify: @escaping () -> Void, onDismiss: @escaping () -> Void
  ) -> some View {
    modifier(ReclassificationAlert(target: target, onReclassify: onReclassify, onDismiss: onDismiss))
  }
}

private struct ReclassificationAlert: ViewModifier {
  let target: String?
  let onReclassify: () -> Void
  let onDismiss: () -> Void
  @State
  private var anchor = WindowAnchor()

  func body(content: Content) -> some View {
    content
      .background(WindowAnchorProbe(anchor: anchor))
      .task(id: target) {
        guard let target else { return }
        guard let window = anchor.view?.window else {
          logger.error("No window for the reclassification alert")
          onDismiss()
          return
        }
        let confirmed = await present(target: target, on: window)
        guard !Task.isCancelled else { return }
        onDismiss()
        if confirmed { onReclassify() }
      }
  }

  private func present(target: String, on window: NSWindow) async -> Bool {
    let alert = NSAlert()
    alert.messageText = "Reclassify Articles?"
    alert.informativeText = "Reclassify existing articles with \(target)? This replaces their category assignments."
    let reclassify = alert.addButton(withTitle: "Reclassify")
    // Return must press no button: a reclassification needs a click.
    reclassify.keyEquivalent = ""
    reclassify.hasDestructiveAction = true
    // NSAlert gives the button titled Cancel the Escape key equivalent.
    alert.addButton(withTitle: "Cancel")
    let sheet = AlertSheet(alert: alert, window: window)
    let response = await withTaskCancellationHandler {
      await alert.beginSheetModal(for: window)
    } onCancel: {
      // The handler runs on no actor, and `endSheet` must run on the main actor.
      Task { @MainActor in sheet.end() }
    }
    return response == .alertFirstButtonReturn
  }
}

private final class AlertSheet {
  private weak var alert: NSAlert?
  private weak var window: NSWindow?

  init(alert: NSAlert, window: NSWindow) {
    self.alert = alert
    self.window = window
  }

  func end() {
    guard let alert, let window else { return }
    window.endSheet(alert.window, returnCode: .cancel)
  }
}

private final class WindowAnchor {
  weak var view: NSView?
}

private struct WindowAnchorProbe: NSViewRepresentable {
  let anchor: WindowAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchor.view = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
