import Foundation
import Observation

/// App-lifetime store of live terminal sessions, keyed by worktree path. Sessions
/// keep running when their window closes or the user switches worktrees, and are
/// reattached when reopened — matching the plan's per-worktree lifecycle.
@Observable
@MainActor
final class TerminalSessionStore {
  private(set) var sessions: [String: TerminalSession] = [:]

  func hasSession(for path: String) -> Bool { sessions[path] != nil }

  /// Returns the existing session for a worktree, or creates and starts one.
  @discardableResult
  func session(for worktree: WorktreeInfo, launchOpencode: Bool = false) -> TerminalSession {
    if let existing = sessions[worktree.path] { return existing }
    let session = TerminalSession(id: worktree.path, directory: worktree.url,
                                  title: worktree.folderName)
    session.onProcessExit = { [weak self] in
      // Keep the closed session around so its output stays readable until the
      // user explicitly closes it; nothing to do here for now.
      _ = self
    }
    sessions[worktree.path] = session
    session.start(initialCommand: launchOpencode ? "opencode" : nil)
    return session
  }

  func closeSession(for path: String) {
    sessions[path]?.terminate()
    sessions[path] = nil
  }
}
