import SwiftUI

/// The right-hand inspector: quick worktree context up top, then Azure DevOps,
/// status, Makefile actions, and notes.
struct WorktreeInspector: View {
  var worktree: WorktreeInfo

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        TopSection(worktree: worktree)

        AzureSection(worktree: worktree)

        CollapsibleCard(title: "Status", systemImage: "chart.bar.doc.horizontal", stateKey: "status") {
          StatusSectionBody(worktree: worktree)
        }

        if MakefileParser.hasMakefile(in: worktree.url) {
          CollapsibleCard(title: "Makefile Actions", systemImage: "hammer", stateKey: "makefile") {
            MakefileSectionBody(worktree: worktree)
          }
        }

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

/// Header and quick actions. Work item / Figma / Slack links live in the "+"
/// tab menu now, alongside the other quick-open destinations; this stays a
/// compact "open this worktree elsewhere" row.
private struct TopSection: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(WorktreeTabsStore.self) private var tabsStore
  @Environment(WorktreeLinksStore.self) private var linksStore
  var worktree: WorktreeInfo

  @State private var showingEditor = false
  @State private var confirmingDelete = false
  @State private var showingDeleteError = false
  @State private var deleteErrorMessage: String?
  /// Bumped on `.branchConfigChanged` so quick links pick up config edits
  /// without reopening the worktree — the config lives on disk, so there's
  /// nothing observable to depend on otherwise.
  @State private var linksReloadToken = 0
  private let forkURL = AppOpener.forkAppURL()
  private let vscodeURL = AppOpener.vscodeAppURL()

  private var quickLinks: [QuickLink] {
    _ = linksReloadToken
    return QuickLinks.resolve(for: worktree, linksStore: linksStore)
  }

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
        if worktree.branch != nil {
          Button("Edit Config", systemImage: "slider.horizontal.3") { showingEditor = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("e", modifiers: .command)
        }
        if !workspace.isMainWorktree(worktree) {
          Button("Delete Worktree", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
      }

      let links = quickLinks
      if !links.isEmpty {
        QuickLinksRow(worktree: worktree, links: links)
      }

      HStack(spacing: 8) {
        Button("Finder", systemImage: "folder") { AppOpener.revealInFinder(worktree.url) }
        if let vscodeURL {
          Button { AppOpener.openInVSCode(worktree.url) } label: {
            Label {
              Text("VS Code")
            } icon: {
              Image(nsImage: AppOpener.appIcon(vscodeURL))
                .resizable().frame(width: 15, height: 15)
            }
          }
        }
        if let forkURL {
          Button { AppOpener.openInFork(worktree.url) } label: {
            Label {
              Text("Fork")
            } icon: {
              Image(nsImage: AppOpener.appIcon(forkURL))
                .resizable().frame(width: 15, height: 15)
            }
          }
        }
      }
      .controlSize(.small)
      .buttonStyle(.bordered)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: .rect(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    .onReceive(NotificationCenter.default.publisher(for: .branchConfigChanged)) { _ in
      linksReloadToken += 1
    }
    .sheet(isPresented: $showingEditor) {
      if let branch = worktree.branch {
        SharedConfigEditor(worktree: worktree, branch: branch)
      }
    }
    .confirmationDialog("Delete Worktree?", isPresented: $confirmingDelete) {
      Button("Delete", role: .destructive) { delete(force: false) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This deletes \(worktree.folderName) — the branch and its history are untouched, but any uncommitted changes in the working directory will be lost. This can't be undone.")
    }
    .alert("Couldn't Delete Worktree", isPresented: $showingDeleteError) {
      Button("Force Delete", role: .destructive) { delete(force: true) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(deleteErrorMessage ?? "")
    }
  }

  private func delete(force: Bool) {
    Task {
      if let error = await workspace.deleteWorktree(worktree, tabsStore: tabsStore, linksStore: linksStore, force: force) {
        deleteErrorMessage = error
        showingDeleteError = true
      }
    }
  }
}

/// Compact, sentence-style status: modified files, sync vs remote, sync vs parent.
struct StatusSectionBody: View {
  @Environment(WorkspaceModel.self) private var workspace
  var worktree: WorktreeInfo

  var body: some View {
    let status = workspace.statuses[worktree.path] ?? WorktreeStatus()
    VStack(alignment: .leading, spacing: 8) {
      workingTreeRow(status)
      remoteRow(status)
      baseRow(status)

      HStack(spacing: 8) {
        if let date = workspace.lastFetch[worktree.path] {
          Text("Fetched \(date.formatted(.relative(presentation: .named)))")
            .font(.caption2).foregroundStyle(.tertiary)
        }
        Spacer()
        Button("Fetch", systemImage: "arrow.down.circle") { Task { await workspace.fetch(worktree) } }
          .controlSize(.small)
        Button("Reload", systemImage: "arrow.clockwise") { Task { await workspace.reloadStatus(for: worktree) } }
          .controlSize(.small).labelStyle(.iconOnly)
      }
      .padding(.top, 2)
    }
  }

  @ViewBuilder private func workingTreeRow(_ status: WorktreeStatus) -> some View {
    if status.conflicted > 0 {
      StatusLine(icon: "exclamationmark.triangle.fill", tint: .red,
                 text: "\(status.conflicted) file\(status.conflicted == 1 ? "" : "s") in conflict")
    } else if status.changedCount > 0 {
      StatusLine(icon: "pencil.circle.fill", tint: .orange,
                 text: "\(status.changedCount) modified file\(status.changedCount == 1 ? "" : "s") in the worktree")
    } else {
      StatusLine(icon: "checkmark.circle.fill", tint: .green, text: "Working tree is clean")
    }
  }

  @ViewBuilder private func remoteRow(_ status: WorktreeStatus) -> some View {
    if !status.hasUpstream {
      StatusLine(icon: "arrow.up.arrow.down.circle", tint: .secondary, text: "No upstream branch set")
    } else if status.remoteAhead == 0 && status.remoteBehind == 0 {
      StatusLine(icon: "checkmark.circle", tint: .secondary, text: "In sync with its remote")
    } else {
      StatusLine(icon: "arrow.up.arrow.down.circle.fill", tint: .blue,
                 text: "Branch is \(syncText(ahead: status.remoteAhead, behind: status.remoteBehind)) its remote")
    }
  }

  @ViewBuilder private func baseRow(_ status: WorktreeStatus) -> some View {
    if status.hasBase, let base = status.baseName {
      if status.baseAhead == 0 && status.baseBehind == 0 {
        StatusLine(icon: "arrow.triangle.branch", tint: .secondary, text: "Up to date with \(base)")
      } else {
        StatusLine(icon: "arrow.triangle.branch", tint: .purple,
                   text: "Branch is \(syncText(ahead: status.baseAhead, behind: status.baseBehind)) \(base)")
      }
    } else {
      StatusLine(icon: "arrow.triangle.branch", tint: .secondary,
                 text: "No parent branch set (Edit Config)")
    }
  }

  private func syncText(ahead: Int, behind: Int) -> String {
    switch (ahead, behind) {
    case let (a, 0) where a > 0: return "ahead \(a) of"
    case let (0, b) where b > 0: return "behind \(b) of"
    default: return "ahead \(ahead) / behind \(behind) of"
    }
  }
}

private struct StatusLine: View {
  var icon: String
  var tint: Color
  var text: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
      Text(text).font(.callout)
      Spacer(minLength: 0)
    }
  }
}
