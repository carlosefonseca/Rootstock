import SwiftUI
import WebKit

/// Hosts a session's `WKWebView` in SwiftUI. The view is owned by the long-lived
/// `WebTabSession`, so this representable just mounts it — same pattern as
/// `TerminalViewRepresentable`.
struct WebTabViewRepresentable: NSViewRepresentable {
  var session: WebTabSession

  func makeNSView(context: Context) -> WKWebView {
    session.webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
