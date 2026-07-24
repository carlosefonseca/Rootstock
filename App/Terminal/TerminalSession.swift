import Foundation
import Observation
import SwiftTerm
import AppKit

/// One live PTY-backed terminal bound to a tab. Wraps SwiftTerm's
/// `LocalProcessTerminalView` so the same running process can be shown, detached,
/// and shown again as the user switches worktrees, tabs, or reopens the window.
@Observable
@MainActor
final class TerminalSession: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
  let id: String            // session key (e.g. worktree path)
  let directory: URL
  let terminalView: LocalProcessTerminalView

  private(set) var isRunning = false
  private(set) var title: String
  var onProcessExit: (() -> Void)?

  init(id: String, directory: URL, title: String) {
    self.id = id
    self.directory = directory
    self.title = title
    self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    super.init()
    terminalView.processDelegate = self
    terminalView.font = AppSettings.terminalFont()
    // SwiftTerm defaults Option to a Meta-key modifier (sends ESC + key, for
    // Emacs-style Alt bindings), which swallows Option-modified key combos
    // before they can compose characters like @, ç, or ~ on non-US keyboard
    // layouts. Rootstock isn't targeting Meta-key shell workflows, so let
    // Option behave like normal text input instead.
    terminalView.optionAsMetaKey = false
    NotificationCenter.default.addObserver(
      forName: .terminalFontChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.terminalView.font = AppSettings.terminalFont() }
    }
  }

  /// Starts an interactive login shell in the worktree directory. `initialCommand`,
  /// if given, is typed in and run automatically (used to launch `opencode`).
  func start(initialCommand: String? = nil) {
    guard !isRunning else { return }
    isRunning = true
    var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
    env.append("TERM_PROGRAM=Rootstock")
    terminalView.startProcess(executable: "/bin/zsh", args: ["-il"],
                              environment: env, currentDirectory: directory.path)
    if let initialCommand, !initialCommand.isEmpty {
      terminalView.send(txt: "\(initialCommand)\n")
    }
  }

  func sendText(_ text: String) {
    terminalView.send(txt: text)
  }

  func terminate() {
    guard isRunning else { return }
    terminalView.terminate()
  }

  // MARK: LocalProcessTerminalViewDelegate

  nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
    Task { @MainActor in
      isRunning = false
      onProcessExit?()
    }
  }

  nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    Task { @MainActor in if !title.isEmpty { self.title = title } }
  }

  nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
