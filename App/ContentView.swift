import SwiftUI
import SwiftData

struct ContentView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(CrossRepoPRWorkModel.self) private var prWorkModel
  @Environment(\.modelContext) private var context
  @Environment(\.openWindow) private var openWindow
  @State private var showingNewWorktree = false
  @State private var editingTerminalCommandFor: TrackedClone?
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
  @State private var showingSidebarPopover = false

  var body: some View {
    @Bindable var workspace = workspace
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarView(editingTerminalCommandFor: $editingTerminalCommandFor)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
    } detail: {
      if let worktree = workspace.selectedWorktree {
        WorktreeDetailView(worktree: worktree)
          .id(worktree.path)
      } else {
        EmptyDetailView()
      }
    }
    // Attached to the NavigationSplitView (window-level), not the sidebar
    // column — a toolbar on SidebarView itself disappears along with it when
    // the sidebar is collapsed.
    .toolbar {
      // .navigation places these next to the system-provided sidebar toggle
      // on the left, rather than the trailing side macOS defaults to.
      ToolbarItem(placement: .navigation) {
        Menu {
          Button("Track Existing Clone…", systemImage: "folder.badge.plus") { trackClone() }
          Button("New Worktree from Work Item…", systemImage: "plus.rectangle.on.folder") { showingNewWorktree = true }
        } label: {
          Label("Add", systemImage: "plus")
        }
      }
      if columnVisibility == .detailOnly {
        ToolbarItem(placement: .navigation) {
          Button {
            showingSidebarPopover = true
          } label: {
            Label("Worktrees", systemImage: "list.bullet.rectangle.portrait")
          }
          .popover(isPresented: $showingSidebarPopover, arrowEdge: .bottom) {
            SidebarView(editingTerminalCommandFor: $editingTerminalCommandFor)
              .frame(width: 280, height: 420)
              .onChange(of: workspace.selectedPath) {
                showingSidebarPopover = false
              }
          }
        }
      }
      ToolbarItem {
        PRWorkToolbarButton(badgeCount: prWorkModel.badgeCount) { openWindow(id: "pr-work") }
      }
      ToolbarItem {
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task {
            await workspace.refreshAll()
            prWorkModel.refresh(clones: workspace.clones)
          }
        }
        .disabled(workspace.refreshing)
      }
    }
    .sheet(isPresented: $showingNewWorktree) {
      NewWorktreeView()
    }
    .sheet(item: $editingTerminalCommandFor) { clone in
      TerminalCommandEditor(clone: clone) { command in
        workspace.setTerminalInitCommand(command, for: clone)
      }
    }
    .task { workspace.configure(context) }
    // Keeps the toolbar badge populated even if the user never opens the
    // PR-work window. One-shot rather than keyed to the clones list: that
    // list mutates several times in quick succession while clones first load
    // (each mutation would cancel and restart the in-flight aggregation),
    // and the "Refresh"/Cmd+R actions already cover picking up new clones.
    .task {
      prWorkModel.refreshIfStale(clones: workspace.clones)
    }
  }

  private func trackClone() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Track"
    panel.message = "Choose a folder inside a git clone."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      let ok = await workspace.addClone(at: url)
      if !ok {
        let alert = NSAlert()
        alert.messageText = "Not a Git Repository"
        alert.informativeText = "\(url.lastPathComponent) isn't inside a git working tree."
        alert.runModal()
      }
    }
  }
}

/// Opens the "Pull Request Work" window. macOS toolbar buttons have no
/// built-in `.badge()` (unlike List rows), so the count is a manual overlay.
struct PRWorkToolbarButton: View {
  var badgeCount: Int
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      // An explicit outer frame, not just the icon's own tight bounds — a
      // toolbar item clips to its content's natural size, and a badge placed
      // via .offset alone got its second digit clipped off ("23" rendering
      // as "2") because it extended past the plain icon's frame.
      ZStack(alignment: .topTrailing) {
        Image(systemName: "arrow.triangle.pull")
          .frame(width: 18, height: 18)
        if badgeCount > 0 {
          // A fixed-size circle clips a two-digit count — a capsule with a
          // minimum width stays circular for "9" but grows for "24"/"99+".
          Text(badgeCount > 99 ? "99+" : String(badgeCount))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 14, minHeight: 14)
            .background(.red, in: .capsule)
            .offset(x: 8, y: -6)
        }
      }
      .frame(width: 30, height: 22)
    }
    .help(badgeCount > 0 ? "Pull Request Work — \(badgeCount) need your attention" : "Pull Request Work")
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
