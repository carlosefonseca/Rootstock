import AppKit

/// Small helpers for handing a worktree off to other tools in the workflow.
enum AppOpener {
  static let forkBundleID = "com.DanPristupov.Fork"

  static func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  /// Opens the worktree in the user's configured terminal app.
  static func openInTerminal(_ url: URL) {
    NSWorkspace.shared.open([url], withApplicationAt: AppSettings.terminalAppURL,
                            configuration: NSWorkspace.OpenConfiguration())
  }

  /// The Fork app URL, or nil when Fork isn't installed.
  static func forkAppURL() -> URL? {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: forkBundleID) {
      return url
    }
    let fallback = URL(fileURLWithPath: "/Applications/Fork.app")
    return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
  }

  static func openInFork(_ url: URL) {
    guard let fork = forkAppURL() else { return }
    NSWorkspace.shared.open([url], withApplicationAt: fork,
                            configuration: NSWorkspace.OpenConfiguration())
  }

  static func appIcon(_ url: URL) -> NSImage {
    NSWorkspace.shared.icon(forFile: url.path)
  }

  static func open(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }

  /// Opens a Slack channel URL via the native app deep link when the archive id
  /// is recognisable, falling back to the web URL.
  static func openSlack(_ urlString: String) {
    if let comps = URLComponents(string: urlString),
       let last = comps.path.split(separator: "/").last,
       last.hasPrefix("C") || last.hasPrefix("G") {
      open("slack://channel?id=\(last)")
      return
    }
    open(urlString)
  }
}

/// Every button that opens a web URL (PR, work item, pipeline, Figma) goes
/// through here: in-app by default, Cmd or Option held opens it in the system
/// browser instead — the escape hatch for OAuth flows, browser extensions, or
/// anything the embedded WKWebView can't handle. Slack is intentionally not
/// routed through this — its native app is the better default there.
enum WebLinkOpener {
  @MainActor
  static func open(_ urlString: String, title: String, systemImage: String,
                   worktree: WorktreeInfo, tabsStore: WorktreeTabsStore) {
    let flags = NSEvent.modifierFlags
    if flags.contains(.command) || flags.contains(.option) {
      AppOpener.open(urlString)
    } else {
      tabsStore.openWebTab(title: title, systemImage: systemImage, urlString: urlString, for: worktree)
    }
  }
}
