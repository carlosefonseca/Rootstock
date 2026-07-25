import SwiftUI
import AppKit

struct SidebarView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(CrossRepoPRWorkModel.self) private var prWorkModel
  @Environment(\.openWindow) private var openWindow
  @State private var showingNewWorktree = false
  @State private var editingTerminalCommandFor: TrackedClone?

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
              Button("Terminal Command…") { editingTerminalCommandFor = clone }
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
private struct PRWorkToolbarButton: View {
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

private struct TerminalCommandEditor: View {
  @Environment(\.dismiss) private var dismiss
  var clone: TrackedClone
  var onSave: (String?) -> Void

  @State private var command = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Terminal Command").font(.title3.weight(.semibold))
      Text("Typed automatically into every new terminal tab in \(clone.displayName), right after the shell starts. Stored on this Mac only — never written to the repo.")
        .font(.caption).foregroundStyle(.secondary)
      TextField("Command", text: $command, prompt: Text("e.g. nvm use"))
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
          onSave(trimmed.isEmpty ? nil : trimmed)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 400)
    .onAppear { command = clone.terminalInitCommand ?? "" }
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
