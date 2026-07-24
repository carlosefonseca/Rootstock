import Foundation
import Observation
import SwiftTerm
import AppKit

/// `LocalProcessTerminalView` with `optionAsMetaKey` off (see below), but with
/// Option+Left/Right arrow special-cased back to the classic emacs word-jump
/// escape codes — the one piece of "Option as Meta" behavior worth keeping,
/// since it doesn't collide with character composition. SwiftTerm's own
/// `keyDown` override is `public`, not `open`, so it can't be overridden from
/// here — `performKeyEquivalent` isn't overridden by SwiftTerm at all, and the
/// window calls it before ordinary key dispatch, so it works as an interception
/// point instead.
private final class RootstockTerminalView: LocalProcessTerminalView {
  private static let leftArrowKeyCode: UInt16 = 123
  private static let rightArrowKeyCode: UInt16 = 124

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // performKeyEquivalent walks every view in the window, not just the first
    // responder — without this check, Option+Arrow would be stolen from other
    // text fields (e.g. the Notes editor) whenever this view merely exists.
    guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
    // Keyed off the hardware keyCode rather than charactersIgnoringModifiers —
    // the latter isn't reliably populated for arrow keys on every event source.
    // Arrow keys always carry the incidental .function/.numericPad flags on top
    // of whatever's actually held, so only the real modifier keys are compared.
    let heldModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if heldModifiers == .option {
      switch event.keyCode {
      case Self.leftArrowKeyCode:
        send(EscapeSequences.emacsBack)
        return true
      case Self.rightArrowKeyCode:
        send(EscapeSequences.emacsForward)
        return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
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

  init(id: String, directory: URL, title: String) {
    self.id = id
    self.directory = directory
    self.title = title
    self.terminalView = RootstockTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    super.init()
    terminalView.processDelegate = self
    terminalView.font = AppSettings.terminalFont()
    // SwiftTerm defaults Option to a Meta-key modifier (sends ESC + key, for
    // Emacs-style Alt bindings), which swallows Option-modified key combos
    // before they can compose characters like @, ç, or ~ on non-US keyboard
    // layouts. Rootstock isn't targeting Meta-key shell workflows, so let
    // Option behave like normal text input instead — except Option+Arrow,
    // handled above, since word-jump doesn't collide with composition.
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
