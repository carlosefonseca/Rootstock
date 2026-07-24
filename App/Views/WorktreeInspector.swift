import SwiftUI

/// The right-hand inspector: quick worktree context up top, then status, Makefile
/// actions, config, and notes — the panel that used to be the whole detail view.
struct WorktreeInspector: View {
  var worktree: WorktreeInfo

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        TopSection(worktree: worktree)

        CollapsibleCard(title: "Status", systemImage: "chart.bar.doc.horizontal", stateKey: "status") {
          StatusSectionBody(worktree: worktree)
        }

        if MakefileParser.hasMakefile(in: worktree.url) {
          CollapsibleCard(title: "Makefile Actions", systemImage: "hammer", stateKey: "makefile") {
            MakefileSectionBody(worktree: worktree)
          }
        }

        AzureSection(worktree: worktree)

        if let branch = worktree.branch {
          CollapsibleCard(title: "Notes", systemImage: "note.text", stateKey: "notes") {
            NotesSectionBody(worktree: worktree, branch: branch)
          }
        }
      }
      .padding(12)
    }
  }
}

/// Header plus the most-used, always-visible controls: work item id and the
/// Figma / Slack open buttons, with a button to open the full config editor.
private struct TopSection: View {
  @Environment(WorkspaceModel.self) private var workspace
  var worktree: WorktreeInfo

  @State private var config = BranchConfig()
  @State private var workItemID = ""
  @State private var showingEditor = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "arrow.triangle.branch")
          .font(.title3)
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 1) {
          Text(worktree.folderName)
            .font(.headline)
            .lineLimit(1)
          Text(worktree.displayBranch)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }

      if worktree.branch != nil {
        HStack(spacing: 6) {
          Image(systemName: "number")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("Work item", text: $workItemID, prompt: Text("Work item ID"))
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .onSubmit { saveWorkItem() }
        }

        HStack(spacing: 8) {
          Button("Figma", systemImage: "paintbrush.pointed") {
            if let url = config.figmaURL { AppOpener.open(url) }
          }
          .disabled((config.figmaURL ?? "").isEmpty)
          Button("Slack", systemImage: "bubble.left.and.bubble.right") {
            if let url = config.slackChannelURL { AppOpener.openSlack(url) }
          }
          .disabled((config.slackChannelURL ?? "").isEmpty)
          Spacer()
          Button("Edit…", systemImage: "slider.horizontal.3") { showingEditor = true }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
      }

      Divider()

      HStack(spacing: 8) {
        Button("Finder", systemImage: "folder") { AppOpener.revealInFinder(worktree.url) }
        Button("Fork", systemImage: "arrow.triangle.pull") { AppOpener.openInFork(worktree.url) }
        Button("Terminal.app", systemImage: "terminal") { AppOpener.openInTerminal(worktree.url) }
      }
      .controlSize(.small)
      .buttonStyle(.bordered)

      Text(worktree.path)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: .rect(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    .task(id: worktree.path) { load() }
    .sheet(isPresented: $showingEditor, onDismiss: load) {
      if let branch = worktree.branch {
        SharedConfigEditor(worktree: worktree, branch: branch)
      }
    }
  }

  private func load() {
    guard let branch = worktree.branch else { return }
    config = BranchConfig.load(worktree: worktree.url, branch: branch)
    workItemID = config.workItemID ?? ""
  }

  private func saveWorkItem() {
    guard let branch = worktree.branch else { return }
    var latest = BranchConfig.load(worktree: worktree.url, branch: branch)
    latest.workItemID = workItemID.isEmpty ? nil : workItemID
    try? latest.save(worktree: worktree.url, branch: branch)
    config = latest
  }
}

struct StatusSectionBody: View {
  @Environment(WorkspaceModel.self) private var workspace
  var worktree: WorktreeInfo

  var body: some View {
    let status = workspace.statuses[worktree.path] ?? WorktreeStatus()
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 16) {
        StatCell(value: "\(status.staged)", label: "Staged")
        StatCell(value: "\(status.unstaged)", label: "Modified")
        StatCell(value: "\(status.untracked)", label: "Untracked")
        if status.conflicted > 0 {
          StatCell(value: "\(status.conflicted)", label: "Conflicts", tint: .red)
        }
      }
      HStack(spacing: 16) {
        StatCell(value: "↑ \(status.ahead)", label: "Ahead")
        StatCell(value: "↓ \(status.behind)", label: "Behind")
        Spacer()
      }
      HStack {
        if let date = workspace.lastFetch[worktree.path] {
          Label("Fetched \(date.formatted(.relative(presentation: .named)))", systemImage: "clock")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Never fetched").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Fetch", systemImage: "arrow.down.circle") {
          Task { await workspace.fetch(worktree) }
        }
        .controlSize(.small)
        Button("Reload", systemImage: "arrow.clockwise") {
          Task { await workspace.reloadStatus(for: worktree) }
        }
        .controlSize(.small)
        .labelStyle(.iconOnly)
      }
    }
  }
}

private struct StatCell: View {
  var value: String
  var label: String
  var tint: Color = .primary

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}

