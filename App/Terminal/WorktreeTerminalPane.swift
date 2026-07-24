import SwiftUI

/// The main surface for a worktree: its live, PTY-backed terminal. Sessions are
/// owned by the store and persist across worktree switches, so jumping between
/// worktrees swaps which running terminal is on screen without killing the others.
struct WorktreeTerminalPane: View {
  @Environment(TerminalSessionStore.self) private var terminals
  var worktree: WorktreeInfo

  @State private var session: TerminalSession?

  var body: some View {
    VStack(spacing: 0) {
      if let session {
        TerminalViewRepresentable(session: session)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      controls
    }
    .task(id: worktree.path) {
      // Attach (creating on first use) the session for this worktree.
      session = terminals.session(for: worktree)
    }
  }

  private var controls: some View {
    HStack(spacing: 8) {
      Circle()
        .fill((session?.isRunning ?? false) ? .green : .secondary)
        .frame(width: 8, height: 8)
      Text((session?.isRunning ?? false) ? "Running" : "Exited")
        .font(.caption).foregroundStyle(.secondary)
      Text(worktree.folderName)
        .font(.caption).foregroundStyle(.tertiary)
      Spacer()
      Button("Run opencode", systemImage: "sparkles") {
        session?.sendText("opencode\n")
      }
      .disabled(!(session?.isRunning ?? false))
      Button("Restart", systemImage: "arrow.clockwise") {
        terminals.closeSession(for: worktree.path)
        session = terminals.session(for: worktree)
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }
}
