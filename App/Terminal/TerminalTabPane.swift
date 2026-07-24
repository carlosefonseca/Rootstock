import SwiftUI

/// A terminal tab's content: the live PTY view plus a thin status/controls bar.
/// The session is owned by the tab itself now (see `MainTab`), so this just
/// renders whichever one it's given.
struct TerminalTabPane: View {
  var session: TerminalSession

  var body: some View {
    VStack(spacing: 0) {
      TerminalViewRepresentable(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      controls
    }
  }

  private var controls: some View {
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
      .disabled(!session.isRunning)
      Button("Restart", systemImage: "arrow.clockwise") {
        session.terminate()
        session.start()
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }
}
