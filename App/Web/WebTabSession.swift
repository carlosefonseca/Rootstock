import AppKit
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

  /// Fired when the user picks "Open in New Tab" from a link's context menu.
  var onOpenInNewTab: ((String) -> Void)?

  init(urlString: String) {
    self.currentURLString = urlString
    self.webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
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

extension WebTabSession: WKUIDelegate {
  /// WKWebView on macOS doesn't expose a way to customize the right-click menu
  /// itself (that API is iOS-only) — but every route to "open this link
  /// elsewhere" funnels through here regardless of how it was triggered:
  /// Cmd/middle-click, a target="_blank" link, or picking the native context
  /// menu's "Open Link in New Window". Returning nil (after grabbing the URL
  /// ourselves) redirects all of them into a Rootstock tab instead of handing
  /// the link to a real separate window.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = navigationAction.request.url {
      onOpenInNewTab?(url.absoluteString)
    }
    return nil
  }
}
