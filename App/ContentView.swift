import SwiftUI
import SwiftData

struct ContentView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(\.modelContext) private var context

  var body: some View {
    @Bindable var workspace = workspace
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
    } detail: {
      if let worktree = workspace.selectedWorktree {
        WorktreeDetailView(worktree: worktree)
          .id(worktree.path)
      } else {
        EmptyDetailView()
      }
    }
    .task { workspace.configure(context) }
  }
}

private struct EmptyDetailView: View {
  var body: some View {
    ContentUnavailableView {
      Label("No Worktree Selected", systemImage: "arrow.triangle.branch")
    } description: {
      Text("Track a clone from the sidebar, then pick a worktree to see its status, actions, and shared config.")
    }
  }
}
