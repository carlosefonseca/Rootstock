import SwiftUI

/// A terminal tab's content: the live PTY view, full height — the shell itself
/// is the interface. Nothing else is shown unless the process has actually
/// died, in which case a thin banner offers the one action that matters then.
struct TerminalTabPane: View {
  var session: TerminalSession

  var body: some View {
    VStack(spacing: 0) {
      TerminalViewRepresentable(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if !session.isRunning {
        Divider()
        exitedBanner
      }
    }
  }

  private var exitedBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
      Text("Shell exited").font(.caption).foregroundStyle(.secondary)
      Spacer()
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
