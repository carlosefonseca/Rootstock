import Foundation
import Observation
import SwiftTerm
import AppKit

/// Copies the selection to the clipboard as it's made — the "select to copy"
/// convention most terminal emulators (Terminal.app, iTerm2) follow, instead
/// of requiring an explicit Cmd+C. `selectionChanged` is `open` on
/// `TerminalView` but the `selection` property backing `copy(_:)` is
/// module-internal, so this goes through the public `getSelection()` instead
/// of reimplementing what `copy(_:)` already does.
final class CopyOnSelectTerminalView: LocalProcessTerminalView {
  override func selectionChanged(source: Terminal) {
    super.selectionChanged(source: source)
    guard let text = getSelection(), !text.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}

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
  private var optionKeyMonitor: Any?

  init(id: String, directory: URL, title: String) {
    self.id = id
    self.directory = directory
    self.title = title
    self.terminalView = CopyOnSelectTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    super.init()
    terminalView.processDelegate = self
    terminalView.font = AppSettings.terminalFont()
    // SwiftTerm defaults Option to a Meta-key modifier (sends ESC + key, for
    // Emacs-style Alt bindings), which swallows Option-modified key combos
    // before they can compose characters like @, ç, or ~ on non-US keyboard
    // layouts. Rootstock isn't targeting Meta-key shell workflows, so let
    // Option behave like normal text input instead — except Option+Arrow and
    // Option+Delete, restored below, since word-jump/word-delete don't
    // collide with composition.
    terminalView.optionAsMetaKey = false
    NotificationCenter.default.addObserver(
      forName: .terminalFontChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.terminalView.font = AppSettings.terminalFont() }
    }
    // A local event monitor rather than overriding keyDown/performKeyEquivalent:
    // SwiftTerm's own keyDown is `public`, not `open`, so it can't be
    // overridden from here, and performKeyEquivalent turns out to not be
    // called for every key (AppKit only routes some keys, like arrows,
    // through it by convention — Delete isn't one of them). A local monitor
    // sees every keyDown in the app before normal dispatch, regardless.
    optionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.terminalView.window?.firstResponder === self.terminalView else { return event }
      guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .option else { return event }
      switch event.keyCode {
      case 123: // Left arrow
        self.terminalView.send(EscapeSequences.emacsBack)
        return nil
      case 124: // Right arrow
        self.terminalView.send(EscapeSequences.emacsForward)
        return nil
      case 51: // Delete/Backspace
        self.terminalView.send(EscapeSequences.cmdEsc)
        self.terminalView.send(EscapeSequences.cmdDel)
        return nil
      default:
        return event
      }
    }
  }

  deinit {
    MainActor.assumeIsolated {
      if let optionKeyMonitor { NSEvent.removeMonitor(optionKeyMonitor) }
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
