import AppKit

/// Small helpers for handing a worktree off to other tools in the workflow.
enum AppOpener {
  static func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  static func openInTerminal(_ url: URL) {
    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    NSWorkspace.shared.open([url], withApplicationAt: terminal,
                            configuration: NSWorkspace.OpenConfiguration())
  }

  /// Opens the worktree in Fork if installed; falls back to revealing in Finder.
  static func openInFork(_ url: URL) {
    let fork = URL(fileURLWithPath: "/Applications/Fork.app")
    if FileManager.default.fileExists(atPath: fork.path) {
      NSWorkspace.shared.open([url], withApplicationAt: fork,
                              configuration: NSWorkspace.OpenConfiguration())
    } else {
      revealInFinder(url)
    }
  }

  static func open(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }
}
