import SwiftUI

struct WorktreeDetailView: View {
  @Environment(WorkspaceModel.self) private var workspace
  var worktree: WorktreeInfo

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HeaderSection(worktree: worktree)

        CollapsibleCard(title: "Status", systemImage: "chart.bar.doc.horizontal", stateKey: "status") {
          StatusSectionBody(worktree: worktree)
        }

        if MakefileParser.hasMakefile(in: worktree.url) {
          CollapsibleCard(title: "Makefile Actions", systemImage: "hammer", stateKey: "makefile") {
            MakefileSectionBody(worktree: worktree)
          }
        }

        AzurePlaceholderCard()

        if let branch = worktree.branch {
          CollapsibleCard(title: "Shared Config", systemImage: "person.2", stateKey: "shared") {
            SharedConfigSectionBody(worktree: worktree, branch: branch)
          }
          CollapsibleCard(title: "Notes", systemImage: "note.text", stateKey: "notes") {
            NotesSectionBody(worktree: worktree, branch: branch)
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(worktree.folderName)
    .navigationSubtitle(worktree.displayBranch)
  }
}

private struct HeaderSection: View {
  var worktree: WorktreeInfo

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "arrow.triangle.branch")
          .font(.title2)
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(worktree.folderName)
            .font(.title2.weight(.semibold))
          Text(worktree.displayBranch)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      Text(worktree.path)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)

      HStack {
        Button("Reveal in Finder", systemImage: "folder") { AppOpener.revealInFinder(worktree.url) }
        Button("Terminal", systemImage: "terminal") { AppOpener.openInTerminal(worktree.url) }
        Button("Fork", systemImage: "arrow.triangle.pull") { AppOpener.openInFork(worktree.url) }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: .rect(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
  }
}

private struct StatusSectionBody: View {
  @Environment(WorkspaceModel.self) private var workspace
  var worktree: WorktreeInfo

  var body: some View {
    let status = workspace.statuses[worktree.path] ?? WorktreeStatus()
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 20) {
        StatCell(value: "\(status.staged)", label: "Staged")
        StatCell(value: "\(status.unstaged)", label: "Modified")
        StatCell(value: "\(status.untracked)", label: "Untracked")
        if status.conflicted > 0 {
          StatCell(value: "\(status.conflicted)", label: "Conflicts", tint: .red)
        }
      }
      HStack(spacing: 20) {
        StatCell(value: "↑ \(status.ahead)", label: "Ahead")
        StatCell(value: "↓ \(status.behind)", label: "Behind")
        Spacer()
      }
      HStack {
        if let date = workspace.lastFetch[worktree.path] {
          Label("Fetched \(date.formatted(.relative(presentation: .named)))",
                systemImage: "clock")
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

/// Placeholder for the Azure DevOps sections (PR / pipeline / work item) — the
/// REST client and credential resolution are a planned follow-up phase.
private struct AzurePlaceholderCard: View {
  var body: some View {
    CollapsibleCard(title: "Azure DevOps", systemImage: "cloud", stateKey: "azure") {
      Label("Pull request, pipeline, and work-item integration is coming in a later phase.",
            systemImage: "hammer.circle")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
