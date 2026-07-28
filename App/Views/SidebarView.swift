import SwiftUI
import AppKit

struct SidebarView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Binding var editingTerminalCommandFor: TrackedClone?

  var body: some View {
    @Bindable var workspace = workspace
    List(selection: $workspace.selectedPath) {
      if !workspace.recentWorktrees.isEmpty {
        Section("Recents") {
          ForEach(workspace.recentWorktrees) { worktree in
            WorktreeRow(worktree: worktree, status: workspace.statuses[worktree.path],
                        cloneName: workspace.clone(forWorktree: worktree)?.displayName)
              .tag(worktree.path)
          }
        }
      }
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

struct TerminalCommandEditor: View {
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
  var cloneName: String? = nil

  var body: some View {
    HStack(spacing: 8) {
      StatusDot(dot: status?.dot ?? .clean)
        .help(dotHelp)
      VStack(alignment: .leading, spacing: 1) {
        Text(worktree.folderName)
          .lineLimit(1)
        Text(subtitle)
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

  private var subtitle: String {
    guard let cloneName else { return worktree.displayBranch }
    return "\(cloneName) · \(worktree.displayBranch)"
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
