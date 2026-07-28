import AppKit
import SwiftUI

/// The Azure DevOps card: pull request, pipeline, and work item for the worktree.
struct AzureSection: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(WorktreeTabsStore.self) private var tabsStore
  @Environment(WorktreeLinksStore.self) private var linksStore
  var worktree: WorktreeInfo

  @State private var model = WorktreeAzureModel()
  /// Guards against overlapping reloads — the initial `.task`, the manual Reload
  /// button, and the config-change notification can all trigger one independently.
  /// Without this, an in-flight reload racing a newer one could finish last and
  /// apply stale results.
  @State private var reloadTask: Task<Void, Never>?

  var body: some View {
    CollapsibleCard(title: "Azure DevOps", systemImage: "cloud", stateKey: "azure") {
      if model.phase != .notConfigured {
        Button("Reload", systemImage: "arrow.clockwise") { startReload() }
          .controlSize(.small).labelStyle(.iconOnly).buttonStyle(.borderless)
      }
    } content: {
      content
    }
    .task(id: worktree.path) { startReload() }
    .onReceive(NotificationCenter.default.publisher(for: .branchConfigChanged)) { _ in
      startReload()
    }
    .onDisappear { reloadTask?.cancel() }
  }

  private func startReload() {
    reloadTask?.cancel()
    reloadTask = Task { await reload() }
  }

  private func reload() async {
    guard !Task.isCancelled else { return }
    let clone = workspace.clone(forWorktree: worktree)
    let resolvedRemote = AzureRemote.parse(clone?.remoteURL)
    await model.load(worktree: worktree, remote: resolvedRemote)

    if let pr = model.pr, let remote = model.remote {
      linksStore.setPullRequestURL(remote.pullRequestURL(id: pr.pullRequestId), for: worktree)
    } else {
      linksStore.setPullRequestURL(nil, for: worktree)
    }
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .notConfigured:
      Label("Not an Azure DevOps repository.", systemImage: "info.circle")
        .font(.callout).foregroundStyle(.secondary)
    case .idle, .loading:
      HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
        .font(.callout)
    case .failed(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
        Button("Retry") { Task { await reload() } }.controlSize(.small)
      }
    case .loaded:
      loadedContent
    }
  }

  @ViewBuilder private var loadedContent: some View {
    PullRequestCard(pr: model.pr, unresolved: model.unresolved, pipelines: model.pipelines, remote: model.remote,
                    branch: worktree.branch, worktree: worktree, tabsStore: tabsStore)
    if !model.additionalPRs.isEmpty {
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        Label("Additional Pull Requests", systemImage: "arrow.triangle.pull").font(.subheadline.weight(.medium))
        ForEach(model.additionalPRs) { entry in
          AdditionalPRCard(entry: entry, worktree: worktree, tabsStore: tabsStore)
        }
      }
    }
    if !model.workItems.isEmpty || model.detectedWorkItem != nil {
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        Label("Work Items", systemImage: "checklist").font(.subheadline.weight(.medium))
        ForEach(model.workItems) { entry in
          WorkItemCard(entry: entry, worktree: worktree, tabsStore: tabsStore)
        }
        if let detected = model.detectedWorkItem {
          DetectedWorkItemRow(url: detected) {
            if let branch = worktree.branch { model.confirmDetectedWorkItem(worktree: worktree, branch: branch) }
          }
        }
      }
    }
  }
}

// MARK: Pull request

private struct PullRequestCard: View {
  var pr: ADOPullRequest?
  var unresolved: Int
  var pipelines: [WorktreeAzureModel.Pipeline]
  var remote: AzureRemote?
  var branch: String?
  var worktree: WorktreeInfo
  var tabsStore: WorktreeTabsStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Pull Request", systemImage: "arrow.triangle.pull").font(.subheadline.weight(.medium))

      if let pr {
        HStack(spacing: 6) {
          StatusPill(text: (pr.isDraft ?? false) ? "Draft" : pr.status.capitalized,
                     tint: (pr.isDraft ?? false) ? .secondary : .blue)
          if pr.mergeStatus == "conflicts" {
            StatusPill(text: "Conflicts", tint: .red)
          }
          // String(_:), not raw Int interpolation — Text(_:) parses an
          // interpolated Int through LocalizedStringKey's number formatting,
          // which inserts a locale thousands separator for values >= 1000.
          Text("#\(String(pr.pullRequestId))").font(.caption.monospaced()).foregroundStyle(.secondary)
          Spacer()
          Button("Open", systemImage: "arrow.up.right.square") {
            if let remote {
              WebLinkOpener.open(remote.pullRequestURL(id: pr.pullRequestId), title: "Pull Request",
                                 systemImage: "arrow.triangle.pull", worktree: worktree, tabsStore: tabsStore)
            }
          }
          .controlSize(.small).labelStyle(.iconOnly)
        }
        Text(pr.title).font(.callout).lineLimit(2)

        if !pipelines.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(pipelines) { pipeline in
              PipelinePill(pipeline: pipeline, worktree: worktree, tabsStore: tabsStore)
            }
          }
        }

        if let reviewers = pr.reviewers, !reviewers.isEmpty {
          ReviewerRow(reviewers: reviewers, org: remote?.org ?? "")
        }
        if unresolved > 0 {
          Label("\(unresolved) unresolved comment\(unresolved == 1 ? "" : "s")",
                systemImage: "bubble.left")
            .font(.caption).foregroundStyle(.orange)
        }
      } else {
        HStack {
          Text("No active pull request.").font(.callout).foregroundStyle(.secondary)
          Spacer()
          if let remote, let branch {
            Button("Create PR", systemImage: "plus") {
              WebLinkOpener.open(remote.createPRURL(sourceBranch: branch, targetBranch: nil), title: "Pull Request",
                                 systemImage: "arrow.triangle.pull", worktree: worktree, tabsStore: tabsStore)
            }
            .controlSize(.small)
          }
        }

        if !pipelines.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(pipelines) { pipeline in
              PipelinePill(pipeline: pipeline, worktree: worktree, tabsStore: tabsStore)
            }
          }
        }
      }
    }
  }
}

private struct ReviewerRow: View {
  var reviewers: [ADOReviewer]
  var org: String

  var body: some View {
    HStack(spacing: 4) {
      ForEach(reviewers) { reviewer in
        ReviewerChip(reviewer: reviewer, org: org)
      }
    }
  }
}

private struct ReviewerChip: View {
  var reviewer: ADOReviewer
  var org: String

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable()
      } else {
        Text(initials(reviewer.displayName))
          .font(.caption2.weight(.bold))
          .foregroundStyle(.white)
          .frame(width: 24, height: 24)
          .background(color, in: .circle)
      }
    }
    .frame(width: 24, height: 24)
    .clipShape(.circle)
    .overlay(alignment: .bottomTrailing) {
      // No vote yet isn't actionable, so it gets no badge at all rather than
      // a gray circle that reads as clutter without conveying anything.
      if reviewer.voteKind != .noVote {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(color)
          .padding(1)
          .background(.background, in: .circle)
      }
    }
    .help("\(reviewer.displayName) — \(voteText)")
    .task(id: reviewer.imageUrl) {
      image = await AvatarCache.loadImage(org: org, urlString: reviewer.imageUrl)
    }
  }

  private var color: Color {
    switch reviewer.voteKind {
    case .approved, .approvedWithSuggestions: return .green
    case .waiting: return .orange
    case .rejected: return .red
    case .noVote: return .gray
    }
  }

  private var icon: String {
    switch reviewer.voteKind {
    case .approved: return "checkmark"
    case .approvedWithSuggestions: return "checkmark"
    case .waiting: return "clock"
    case .rejected: return "xmark"
    case .noVote: return "circle"
    }
  }

  private var voteText: String {
    switch reviewer.voteKind {
    case .approved: return "Approved"
    case .approvedWithSuggestions: return "Approved with suggestions"
    case .waiting: return "Waiting for author"
    case .rejected: return "Rejected"
    case .noVote: return "No vote"
    }
  }

  private func initials(_ name: String) -> String {
    let parts = name.split(separator: " ")
    let letters = parts.prefix(2).compactMap { $0.first }
    return String(letters).uppercased()
  }
}

/// One row per pipeline definition (e.g. "ios-build", "ios-test"), tagged with
/// whether its latest run was the PR's own validation build or just a plain
/// branch-push build — the two aren't always the same build, which is what
/// made the old single branch-only badge misleading.
private struct PipelinePill: View {
  var pipeline: WorktreeAzureModel.Pipeline
  var worktree: WorktreeInfo
  var tabsStore: WorktreeTabsStore

  var body: some View {
    Button {
      if let url = pipeline.url {
        WebLinkOpener.open(url, title: pipeline.name, systemImage: "checkmark.seal",
                           worktree: worktree, tabsStore: tabsStore)
      }
    } label: {
      HStack(spacing: 6) {
        Text(sourceLabel)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(.secondary.opacity(0.15), in: .capsule)
        Text(pipeline.name).font(.caption).foregroundStyle(.primary)
        if let label = pipeline.label {
          Text(label).font(.caption).foregroundStyle(.secondary)
        }
        Label(text, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(tint)
        Spacer(minLength: 0)
      }
    }
    .buttonStyle(.plain)
    .help(pipeline.url != nil
          ? "\(pipeline.name) — \(sourceHelp) — \(pipeline.label ?? "Latest build") — \(text). Click to open."
          : "\(pipeline.name) — \(sourceHelp) — \(pipeline.label ?? "Latest build") — \(text)")
  }

  private var sourceLabel: String {
    switch pipeline.source {
    case .pullRequest: return "PR"
    case .branch: return "Branch"
    }
  }
  private var sourceHelp: String {
    switch pipeline.source {
    case .pullRequest: return "PR validation build"
    case .branch: return "Branch build"
    }
  }
  private var text: String {
    switch pipeline.state {
    case .succeeded: return "Passed"
    case .failed: return "Failed"
    case .running: return "Running"
    case .none: return "—"
    }
  }
  private var icon: String {
    switch pipeline.state {
    case .succeeded: return "checkmark.seal.fill"
    case .failed: return "xmark.seal.fill"
    case .running: return "clock.arrow.circlepath"
    case .none: return "seal"
    }
  }
  private var tint: Color {
    switch pipeline.state {
    case .succeeded: return .green
    case .failed: return .red
    case .running: return .orange
    case .none: return .secondary
    }
  }
}

// MARK: Additional pull requests

/// A PR attached to the branch beyond the one auto-detected by source branch
/// name — e.g. the work was split across several PRs.
private struct AdditionalPRCard: View {
  var entry: WorktreeAzureModel.AdditionalPREntry
  var worktree: WorktreeInfo
  var tabsStore: WorktreeTabsStore

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        if let pr = entry.pr {
          StatusPill(text: (pr.isDraft ?? false) ? "Draft" : pr.status.capitalized,
                     tint: (pr.isDraft ?? false) ? .secondary : .blue)
          if pr.mergeStatus == "conflicts" { StatusPill(text: "Conflicts", tint: .red) }
        }
        // String(_:), not raw Int interpolation — Text(_:) parses an
        // interpolated Int through LocalizedStringKey's number formatting,
        // which inserts a locale thousands separator for values >= 1000.
        Text("#\(String(entry.url.id))").font(.caption.monospaced()).foregroundStyle(.secondary)
        Spacer()
        Button("Open", systemImage: "arrow.up.right.square") {
          WebLinkOpener.open(entry.url.canonical, title: "PR #\(entry.url.id)",
                             systemImage: "arrow.triangle.pull", worktree: worktree, tabsStore: tabsStore)
        }
        .controlSize(.small).labelStyle(.iconOnly)
      }
      if let title = entry.pr?.title { Text(title).font(.callout).lineLimit(2) }
    }
  }
}

// MARK: Work item

private struct WorkItemCard: View {
  var entry: WorktreeAzureModel.WorkItemEntry
  var worktree: WorktreeInfo
  var tabsStore: WorktreeTabsStore

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        if let item = entry.detail {
          HStack(spacing: 6) {
            if let type = item.type { StatusPill(text: type, tint: .purple) }
            if let state = item.state { StatusPill(text: state, tint: .blue) }
            Text("#\(entry.url.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
          }
        } else {
          Text("#\(entry.url.id)").font(.callout.monospaced()).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Open", systemImage: "arrow.up.right.square") {
          WebLinkOpener.open(entry.url.canonical, title: "Work Item #\(entry.url.id)",
                             systemImage: "checklist", worktree: worktree, tabsStore: tabsStore)
        }
        .controlSize(.small).labelStyle(.iconOnly)
      }
      if let title = entry.detail?.title { Text(title).font(.callout).lineLimit(2) }
    }
  }
}

private struct DetectedWorkItemRow: View {
  var url: WorkItemURL
  var onConfirm: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Label("Found #\(url.id) in the PR description", systemImage: "questionmark.circle")
        .font(.caption).foregroundStyle(.orange)
      Spacer()
      Button("Add") { onConfirm() }.controlSize(.mini)
    }
  }
}

// MARK: Shared

struct StatusPill: View {
  var text: String
  var tint: Color

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(tint.opacity(0.18), in: .capsule)
      .foregroundStyle(tint)
  }
}
