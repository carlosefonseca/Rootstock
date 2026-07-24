import SwiftUI
import AppKit

struct SidebarView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @State private var showingNewWorktree = false

  var body: some View {
    @Bindable var workspace = workspace
    List(selection: $workspace.selectedPath) {
      ForEach(workspace.clones) { clone in
        Section {
          let rows = workspace.worktrees[clone.commonDir] ?? []
          if rows.isEmpty {
            Text("No worktrees")
              .foregroundStyle(.secondary)
              .font(.caption)
          } else {
            ForEach(rows) { worktree in
              WorktreeRow(worktree: worktree, status: workspace.statuses[worktree.path])
                .tag(worktree.path)
            }
          }
        } header: {
          Text(clone.displayName)
            .contextMenu {
              Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clone.rootURL]) }
              Button("Refresh") { Task { await workspace.refreshClone(commonDir: clone.commonDir, rootURL: clone.rootURL) } }
              Divider()
              Button("Stop Tracking", role: .destructive) { workspace.removeClone(clone) }
            }
        }
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if workspace.clones.isEmpty {
        ContentUnavailableView {
          Label("No Clones", systemImage: "folder.badge.plus")
        } description: {
          Text("Track a git clone to see its worktrees here.")
        } actions: {
          Button("Track Clone…") { trackClone() }
        }
      }
    }
    .toolbar {
      ToolbarItem {
        Menu {
          Button("Track Existing Clone…", systemImage: "folder.badge.plus") { trackClone() }
          Button("New Worktree from Work Item…", systemImage: "plus.rectangle.on.folder") { showingNewWorktree = true }
        } label: {
          Label("Add", systemImage: "plus")
        }
      }
      ToolbarItem {
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await workspace.refreshAll() }
        }
        .disabled(workspace.refreshing)
      }
    }
    .sheet(isPresented: $showingNewWorktree) {
      NewWorktreeView()
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

struct WorktreeRow: View {
  var worktree: WorktreeInfo
  var status: WorktreeStatus?

  var body: some View {
    HStack(spacing: 8) {
      StatusDot(dot: status?.dot ?? .clean)
        .help(dotHelp)
      VStack(alignment: .leading, spacing: 1) {
        Text(worktree.folderName)
          .lineLimit(1)
        Text(worktree.displayBranch)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if let status, (status.remoteAhead > 0 || status.remoteBehind > 0) {
        AheadBehindBadge(ahead: status.remoteAhead, behind: status.remoteBehind)
      }
    }
    .padding(.vertical, 2)
  }

  private var dotHelp: String {
    switch status?.dot ?? .clean {
    case .clean: return "Clean"
    case .dirty: return "Uncommitted changes"
    case .ahead: return "Ahead of base"
    case .behind: return "Behind base"
    case .diverged: return "Diverged from base"
    case .conflicted: return "Merge conflicts"
    }
  }
}

struct StatusDot: View {
  var dot: WorktreeStatus.Dot

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 9, height: 9)
  }

  private var color: Color {
    switch dot {
    case .clean: return .green
    case .dirty: return .orange
    case .ahead: return .blue
    case .behind: return .purple
    case .diverged: return .pink
    case .conflicted: return .red
    }
  }
}

struct AheadBehindBadge: View {
  var ahead: Int
  var behind: Int

  var body: some View {
    HStack(spacing: 4) {
      if ahead > 0 {
        Label("\(ahead)", systemImage: "arrow.up").labelStyle(.titleAndIcon)
      }
      if behind > 0 {
        Label("\(behind)", systemImage: "arrow.down").labelStyle(.titleAndIcon)
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .imageScale(.small)
  }
}
