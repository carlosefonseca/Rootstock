import SwiftUI
import SwiftTerm

/// Hosts a session's `LocalProcessTerminalView` in SwiftUI. The NSView is owned by
/// the long-lived `TerminalSession`, so this representable just mounts it.
struct TerminalViewRepresentable: NSViewRepresentable {
  var session: TerminalSession

  func makeNSView(context: Context) -> LocalProcessTerminalView {
    let view = session.terminalView
    // Selecting a tab should let you start typing immediately. The view isn't
    // necessarily attached to a window yet at this exact point, so hop to the
    // next runloop turn before claiming first responder.
    DispatchQueue.main.async {
      view.window?.makeFirstResponder(view)
    }
    return view
  }

  func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
