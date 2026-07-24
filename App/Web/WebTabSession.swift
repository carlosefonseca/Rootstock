import Foundation
import Observation
import WebKit

/// One live `WKWebView` bound to a web tab. Mirrors `TerminalSession`'s shape —
/// owns the platform view, published navigation state drives the Safari-style
/// chrome in `WebTabPane`.
@Observable
@MainActor
final class WebTabSession: NSObject {
  let webView: WKWebView
  private(set) var currentURLString: String
  private(set) var canGoBack = false
  private(set) var canGoForward = false
  private(set) var isLoading = false
  private(set) var title: String?

  /// Fired after each navigation settles, so the tab store can persist the
  /// tab's latest URL without polling.
  var onNavigate: (() -> Void)?

  init(urlString: String) {
    self.currentURLString = urlString
    self.webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    super.init()
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    load(urlString)
  }

  /// Navigates to `raw`, adding an `https://` scheme if none was given —
  /// matches how Safari's address bar treats plain input.
  func load(_ raw: String) {
    guard let url = Self.normalizedURL(raw) else { return }
    currentURLString = raw
    webView.load(URLRequest(url: url))
  }

  func goBack() { webView.goBack() }
  func goForward() { webView.goForward() }
  func reloadOrStop() {
    if isLoading { webView.stopLoading() } else { webView.reload() }
  }

  static func normalizedURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed == "about:blank" { return URL(string: trimmed) }
    if trimmed.contains("://") { return URL(string: trimmed) }
    return URL(string: "https://\(trimmed)")
  }
}

extension WebTabSession: WKNavigationDelegate {
  nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    Task { @MainActor in isLoading = true }
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task { @MainActor in refreshState(from: webView) }
  }

  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    Task { @MainActor in refreshState(from: webView) }
  }

  nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    Task { @MainActor in refreshState(from: webView) }
  }

  private func refreshState(from webView: WKWebView) {
    isLoading = false
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
    title = webView.title?.isEmpty == false ? webView.title : nil
    if let url = webView.url?.absoluteString { currentURLString = url }
    onNavigate?()
  }
}
