import AppKit
import SwiftUI

/// SwiftUI has no gesture for the middle mouse button, so this bridges one in
/// via a local `NSEvent` monitor scoped to the view's own bounds — not an
/// `NSView` method override (`mouseDown`/`otherMouseDown`), which would make
/// the bridging view an actual hit-test target and risk swallowing the
/// left-click/hover gestures already on the SwiftUI content it sits behind.
private struct MiddleClickCatcher: NSViewRepresentable {
  var onMiddleClick: () -> Void

  func makeNSView(context: Context) -> MonitoringView {
    let view = MonitoringView()
    view.onMiddleClick = onMiddleClick
    return view
  }

  func updateNSView(_ nsView: MonitoringView, context: Context) {
    nsView.onMiddleClick = onMiddleClick
  }

  final class MonitoringView: NSView {
    var onMiddleClick: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
        guard let self, event.buttonNumber == 2 else { return event }
        let locationInView = self.convert(event.locationInWindow, from: nil)
        if self.bounds.contains(locationInView) { self.onMiddleClick?() }
        return event
      }
    }

    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
  }
}

extension View {
  /// Middle mouse button click within this view's bounds — e.g. closing a tab
  /// chip, matching the convention every browser and editor already uses.
  func onMiddleClick(perform action: @escaping () -> Void) -> some View {
    background(MiddleClickCatcher(onMiddleClick: action))
  }
}
