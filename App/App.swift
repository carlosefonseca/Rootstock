import SwiftUI
import SwiftData

@main
struct RootstockApp: App {
  @State private var workspace = WorkspaceModel()
  @State private var terminals = TerminalSessionStore()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(workspace)
        .environment(terminals)
        .frame(minWidth: 820, minHeight: 520)
    }
    .modelContainer(for: [TrackedClone.self, BranchNotes.self])
    .commands {
      CommandGroup(after: .sidebar) {
        Button("Refresh All") { Task { await workspace.refreshAll() } }
          .keyboardShortcut("r", modifiers: .command)
      }
    }
  }
}
