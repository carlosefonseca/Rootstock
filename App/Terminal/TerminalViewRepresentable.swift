import SwiftUI
import SwiftTerm

/// Hosts a session's `LocalProcessTerminalView` in SwiftUI. The NSView is owned by
/// the long-lived `TerminalSession`, so this representable just mounts it.
struct TerminalViewRepresentable: NSViewRepresentable {
  var session: TerminalSession

  func makeNSView(context: Context) -> LocalProcessTerminalView {
    session.terminalView
  }

  func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
