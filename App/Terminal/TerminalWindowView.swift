import SwiftUI

/// The full, resizable terminal window for a worktree, opened via `openWindow`
/// with the worktree path as its value.
struct TerminalWindowView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(TerminalSessionStore.self) private var terminals
  var path: String

  private var worktree: WorktreeInfo? {
    workspace.worktrees.values.flatMap { $0 }.first { $0.path == path }
  }

  var body: some View {
    Group {
      if let worktree {
        TerminalContent(worktree: worktree)
      } else {
        ContentUnavailableView("Worktree Unavailable", systemImage: "terminal",
                               description: Text("This worktree is no longer tracked."))
      }
    }
    .frame(minWidth: 480, minHeight: 300)
  }
}

private struct TerminalContent: View {
  @Environment(TerminalSessionStore.self) private var terminals
  @Environment(\.dismiss) private var dismiss
  var worktree: WorktreeInfo

  var body: some View {
    let session = terminals.session(for: worktree)
    VStack(spacing: 0) {
      TerminalViewRepresentable(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      HStack(spacing: 8) {
        Circle()
          .fill(session.isRunning ? .green : .secondary)
          .frame(width: 8, height: 8)
        Text(session.isRunning ? "Running" : "Exited")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Run opencode", systemImage: "sparkles") {
          session.sendText("opencode\n")
        }
        .controlSize(.small)
        .disabled(!session.isRunning)
        Button("Restart", systemImage: "arrow.clockwise") {
          terminals.closeSession(for: worktree.path)
          terminals.session(for: worktree)
        }
        .controlSize(.small)
        Button("Close Session", systemImage: "xmark.circle") {
          terminals.closeSession(for: worktree.path)
          dismiss()
        }
        .controlSize(.small)
      }
      .padding(8)
    }
    .navigationTitle("Terminal — \(worktree.folderName)")
  }
}
