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

  /// Fired when the user right-clicks an Azure DevOps work item / pull request
  /// link and picks "Add as Work Item" / "Add as Pull Request" — attaching the
  /// link to the worktree's branch config without retyping it into a popover.
  var onAddWorkItem: ((WorkItemURL) -> Void)?
  var onAddPullRequest: ((PullRequestURL) -> Void)?

  /// The href of the link the last right-click landed on, reported by the
  /// `contextmenu` user script (empty when the click wasn't on a link). WebKit
  /// dispatches that JS event to the web process before asking the UI process
  /// for a menu, so by the time `willOpenMenu` runs this already reflects the
  /// current click.
  private var contextLinkHref: String?

  /// Strong references to unparented popup webviews (see `createWebViewWith`)
  /// — kept alive between their creation and their own `window.close()`.
  private var childPopups: [WKWebView] = []

  /// Tracks `webView.url`/`title` via KVO rather than relying solely on
  /// `WKNavigationDelegate` callbacks. Those callbacks only fire for real
  /// navigations — a single-page app like Azure DevOps' work-item view
  /// updates its URL via `history.pushState`/`replaceState` while routing
  /// client-side, which never triggers `didFinish`/`didFail`. Without this,
  /// the address bar can get stuck showing the last real navigation (e.g. an
  /// auth callback URL) indefinitely while the page underneath has moved on.
  private var urlObservation: NSKeyValueObservation?
  private var titleObservation: NSKeyValueObservation?
  /// An observer token, never view state — and `nonisolated(unsafe)` so
  /// `deinit` (which isn't actor-isolated) can unregister it. Only ever
  /// assigned once, in `init`.
  @ObservationIgnored private nonisolated(unsafe) var zoomObserver: NSObjectProtocol?

  init(urlString: String) {
    self.currentURLString = urlString
    let configuration = WKWebViewConfiguration()
    // A bare WKWebView doesn't self-identify as Safari at all — its default
    // UA is missing "Version/X Safari/605.1.15" entirely, just the generic
    // "AppleWebKit/605.1.15 (KHTML, like Gecko)" prefix. Sites that
    // browser-sniff to pick their ITP-compatibility strategy (Safari
    // specifically needs different handling than most browsers for
    // third-party cookies) can end up choosing the wrong path for an
    // unrecognized WebKit-based UA instead of whatever they specifically
    // adapt for Safari. Matching Safari's own installed version exactly gets
    // this webview treated the same way Safari itself would be.
    configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix
    let controller = WKUserContentController()
    controller.addUserScript(WKUserScript(source: Self.contextLinkScript,
                                          injectionTime: .atDocumentStart,
                                          forMainFrameOnly: false))
    configuration.userContentController = controller
    let webView = WebContextMenuWebView(frame: .zero, configuration: configuration)
    self.webView = webView
    super.init()
    // A weak hop, since the controller is reachable from the webview this
    // session owns — registering `self` directly would retain-cycle the whole
    // webview alive after its tab closes.
    controller.add(WeakScriptMessageHandler(target: self), name: Self.contextLinkMessage)
    webView.additionalMenuItems = { [weak self] in self?.linkMenuItems() ?? [] }
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    // Lets Safari's Develop menu attach to this webview (right-click > Inspect
    // Element, or Safari > Develop > Rootstock) — needed to debug page issues
    // like stuck 401s on specific asset requests from inside the app itself.
    webView.isInspectable = true
    urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
      Task { @MainActor in self?.refreshState(from: webView) }
    }
    titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
      Task { @MainActor in self?.refreshState(from: webView) }
    }
    // Another tab on the same host zooming should resize this one too, rather
    // than the two drifting apart until one of them navigates again.
    zoomObserver = NotificationCenter.default.addObserver(
      forName: .webZoomChanged, object: nil, queue: .main) { [weak self] note in
      let host = note.userInfo?["host"] as? String
      Task { @MainActor in
        guard let self, host == nil || host == self.currentHost else { return }
        self.applyStoredZoom()
      }
    }
    load(urlString)
  }

  deinit {
    if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
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

  /// Backs Cmd+R, which every browser treats as "reload" unconditionally —
  /// unlike the toolbar button, which doubles as Stop mid-load.
  func reload() { webView.reload() }

  /// Backs the Cmd+/Cmd- "zoom" shortcut when this tab is focused. Persisted
  /// per hostname (Safari-style) rather than per tab, so zooming one DevOps
  /// work item sizes every DevOps tab the same way, now and on next launch.
  func zoomIn() { setZoom(min(3.0, webView.pageZoom + 0.1)) }
  func zoomOut() { setZoom(max(0.5, webView.pageZoom - 0.1)) }
  func zoomReset() { setZoom(1.0) }

  /// The live zoom, mirrored into observable state so the chrome can show it.
  private(set) var pageZoom: Double = 1.0
  /// Bumped only by the zoom *commands* — not by `applyStoredZoom` — so the
  /// on-screen indicator appears when the user zooms, and stays out of the way
  /// when a page merely loads at its stored size.
  private(set) var userZoomCount = 0

  private func setZoom(_ zoom: Double) {
    webView.pageZoom = zoom
    pageZoom = zoom
    userZoomCount += 1
    if let host = currentHost { AppSettings.setWebZoom(zoom, forHost: host) }
  }

  private var currentHost: String? {
    webView.url?.host() ?? Self.normalizedURL(currentURLString)?.host()
  }

  /// Re-applies the stored zoom for whatever host the page is now on. Called
  /// after each navigation (the host can change mid-tab) and when another tab
  /// changes the same host's zoom.
  private func applyStoredZoom() {
    guard let host = currentHost else { return }
    let stored = AppSettings.webZoom(forHost: host) ?? 1.0
    if abs(webView.pageZoom - stored) > 0.001 { webView.pageZoom = stored }
    pageZoom = stored
  }

  static func normalizedURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed == "about:blank" { return URL(string: trimmed) }
    if trimmed.contains("://") { return URL(string: trimmed) }
    return URL(string: "https://\(trimmed)")
  }

  // MARK: Link context menu

  private static let contextLinkMessage = "rootstockContextLink"

  /// Reports the link under a right-click to the native side. Listens in the
  /// capture phase and on every frame, so pages that swallow `contextmenu` on
  /// their own elements (Azure DevOps' boards do) still tell us what was hit.
  private static let contextLinkScript = """
  document.addEventListener("contextmenu", function (event) {
    var target = event.target;
    var link = target && target.closest ? target.closest("a") : null;
    window.webkit.messageHandlers.\(contextLinkMessage).postMessage(link ? link.href : "");
  }, true);
  """

  fileprivate func receiveScriptMessage(named name: String, body: Any) {
    guard name == Self.contextLinkMessage, let href = body as? String else { return }
    contextLinkHref = href
  }

  /// The Rootstock-specific items prepended to WebKit's own right-click menu.
  /// Both parsers already require an Azure DevOps host (`dev.azure.com` or the
  /// legacy `{org}.visualstudio.com`) plus the right path shape, so a link that
  /// parses is by definition one we can attach.
  private func linkMenuItems() -> [NSMenuItem] {
    guard let href = contextLinkHref, !href.isEmpty else { return [] }
    var items: [NSMenuItem] = []
    if let workItem = WorkItemURL.parse(href) {
      items.append(menuItem(title: "Add as Work Item #\(workItem.id)",
                            action: #selector(addWorkItemFromMenu(_:)), payload: workItem))
    }
    if let pullRequest = PullRequestURL.parse(href) {
      items.append(menuItem(title: "Add as Pull Request #\(pullRequest.id)",
                            action: #selector(addPullRequestFromMenu(_:)), payload: pullRequest))
    }
    return items
  }

  private func menuItem(title: String, action: Selector, payload: Any) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.representedObject = payload
    return item
  }

  @objc private func addWorkItemFromMenu(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? WorkItemURL else { return }
    onAddWorkItem?(url)
  }

  @objc private func addPullRequestFromMenu(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? PullRequestURL else { return }
    onAddPullRequest?(url)
  }

  /// Reads the installed Safari's actual version rather than hardcoding one,
  /// so it doesn't silently drift stale after a Safari update.
  private static var safariUserAgentSuffix: String {
    let version = Bundle(path: "/Applications/Safari.app")?
      .infoDictionary?["CFBundleShortVersionString"] as? String ?? "17.0"
    return "Version/\(version) Safari/605.1.15"
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
    applyStoredZoom()
    if let url = webView.url {
      currentURLString = url.absoluteString
      // `_MsalSignedInFps` is MSAL's one-shot, sessionStorage-scoped
      // redirect-completion URL — valid only as the tail of a live redirect
      // chain the SPA itself just initiated, then swapped out via
      // history.replaceState. If persisted as "the tab's URL" and reloaded
      // cold on a later launch, MSAL's handleRedirectPromise() has no
      // breadcrumb to resolve back to and the tab is stuck there forever —
      // which also stalls whatever session/token state that flow was
      // supposed to finish (this is why avatar loads kept failing too).
      // Still shown live (it's an honest reflection of where the page is),
      // just never written to disk as the tab's restart point.
      if !url.path.contains("_MsalSignedInFps") {
        onNavigate?()
      }
    }
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

/// Forwards script messages without keeping its target alive — a
/// `WKUserContentController` retains its handlers, and the controller is itself
/// reachable from the webview the session owns. Delivery stays synchronous
/// (no `Task` hop): WebKit dispatches the message and the context-menu request
/// over the same connection, in that order, so hopping would risk the menu
/// being built before the link it was clicked on had landed.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  private weak var target: WebTabSession?

  init(target: WebTabSession) {
    self.target = target
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.receiveScriptMessage(named: message.name, body: message.body)
  }
}

extension WebTabSession: WKUIDelegate {
  /// WKWebView on macOS doesn't expose a way to customize the right-click menu
  /// itself (that API is iOS-only) — but every route to "open this link
  /// elsewhere" funnels through here regardless of how it was triggered:
  /// Cmd/middle-click, a target="_blank" link, or picking the native context
  /// menu's "Open Link in New Window". For those, returning nil (after
  /// grabbing the URL ourselves) redirects them into a Rootstock tab instead
  /// of handing the link to a real separate window.
  ///
  /// Auth libraries (MSAL, etc.) also call `window.open` for their silent
  /// token-renewal popup — used as a fallback when the invisible-iframe silent
  /// SSO gets blocked by WKWebView's third-party cookie policy. That popup
  /// needs a *real* WKWebView so its JS can finish the postMessage/close()
  /// handshake with its opener; redirecting it into a tab instead breaks the
  /// handshake and left the main frame stranded on an internal MSAL callback
  /// URL (`_MsalSignedInFps`), corrupting the DevOps SPA's session/routing —
  /// which is what caused both the persistent avatar 401s and the work-item
  /// URLs not matching what was navigated to. Auth popups are distinguishable
  /// from ordinary link opens by `windowFeatures`: MSAL opens its popup with
  /// explicit width/height, while a plain link open requests default chrome
  /// (no size given).
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard windowFeatures.width != nil || windowFeatures.height != nil else {
      if let url = navigationAction.request.url {
        onOpenInNewTab?(url.absoluteString)
      }
      return nil
    }
    let popup = WKWebView(frame: .zero, configuration: configuration)
    popup.uiDelegate = self
    childPopups.append(popup)
    return popup
  }

  /// Fired when a popup's JS calls `window.close()` — its natural end-of-life
  /// signal (auth popups close themselves once they've posted the token back
  /// to their opener). Drops our strong reference so it can deallocate.
  func webViewDidClose(_ webView: WKWebView) {
    childPopups.removeAll { $0 === webView }
  }
}
