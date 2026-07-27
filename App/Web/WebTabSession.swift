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
  private(set) var favicon: NSImage?
  private var faviconURLString: String?

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

  /// Backs the Cmd+/Cmd- "zoom" shortcut when this tab is focused — per-tab,
  /// not a shared preference, since it's really about this page's content
  /// rather than an app-wide setting (unlike the terminal's font size).
  func zoomIn() { webView.pageZoom = min(3.0, webView.pageZoom + 0.1) }
  func zoomOut() { webView.pageZoom = max(0.5, webView.pageZoom - 0.1) }
  func zoomReset() { webView.pageZoom = 1.0 }

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
    loadFavicon()
  }

  /// Reads the page's declared `<link rel="icon">`, falling back to the
  /// origin's `/favicon.ico` — fetched directly from the site itself rather
  /// than a third-party favicon proxy, since some of these pages are internal.
  private func loadFavicon() {
    webView.evaluateJavaScript(
      "document.querySelector(\"link[rel~='icon']\")?.href || (location.origin + '/favicon.ico')"
    ) { [weak self] result, _ in
      guard let href = result as? String else { return }
      Task { @MainActor [weak self] in
        guard let self, href != self.faviconURLString, let url = URL(string: href) else { return }
        self.faviconURLString = href
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return }
        self.favicon = image
      }
    }
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
