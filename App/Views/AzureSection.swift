import SwiftUI

/// The Azure DevOps card: pull request, pipeline, and work item for the worktree.
struct AzureSection: View {
  @Environment(WorkspaceModel.self) private var workspace
  var worktree: WorktreeInfo

  @State private var model = WorktreeAzureModel()
  @State private var remote: AzureRemote?
  @State private var workItemOrg: String?
  @State private var workItemProject: String?

  var body: some View {
    CollapsibleCard(title: "Azure DevOps", systemImage: "cloud", stateKey: "azure") {
      VStack(alignment: .leading, spacing: 12) {
        content
        if model.phase != .notConfigured {
          HStack {
            Spacer()
            Button("Reload", systemImage: "arrow.clockwise") { Task { await reload() } }
              .controlSize(.small)
              .labelStyle(.iconOnly)
          }
        }
      }
    }
    .task(id: worktree.path) { await reload() }
  }

  private func reload() async {
    let clone = workspace.clone(forWorktree: worktree)
    remote = AzureRemote.parse(clone?.remoteURL)
    let dcdp = clone.map { DcdpConfig.load(worktree: $0.rootURL) } ?? nil
    workItemOrg = dcdp?.workItemOrg ?? AzureSettingsStore.defaultWorkItemOrg
    workItemProject = dcdp?.workItemProject ?? AzureSettingsStore.defaultWorkItemProject
    await model.load(worktree: worktree, remote: remote,
                     workItemOrg: workItemOrg, workItemProject: workItemProject)
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
    PullRequestCard(pr: model.pr, unresolved: model.unresolved, pipeline: model.pipeline, remote: remote,
                    branch: worktree.branch)
    if model.workItemID != nil {
      Divider()
      WorkItemCard(item: model.workItem, id: model.workItemID, guessed: model.workItemGuessed,
                   workItemOrg: workItemOrg ?? remote?.org,
                   onConfirm: {
                     if let branch = worktree.branch { model.confirmWorkItem(worktree: worktree, branch: branch) }
                   })
    }
  }
}

// MARK: Pull request

private struct PullRequestCard: View {
  var pr: ADOPullRequest?
  var unresolved: Int
  var pipeline: WorktreeAzureModel.Pipeline
  var remote: AzureRemote?
  var branch: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Pull Request", systemImage: "arrow.triangle.pull").font(.subheadline.weight(.medium))
        Spacer()
        PipelinePill(pipeline: pipeline)
      }

      if let pr {
        HStack(spacing: 6) {
          StatusPill(text: (pr.isDraft ?? false) ? "Draft" : pr.status.capitalized,
                     tint: (pr.isDraft ?? false) ? .secondary : .blue)
          if pr.mergeStatus == "conflicts" {
            StatusPill(text: "Conflicts", tint: .red)
          }
          Spacer()
          Button("Open", systemImage: "arrow.up.right.square") {
            if let remote { AppOpener.open(remote.pullRequestURL(id: pr.pullRequestId)) }
          }
          .controlSize(.small).labelStyle(.iconOnly)
        }
        Text(pr.title).font(.callout).lineLimit(2)

        if let reviewers = pr.reviewers, !reviewers.isEmpty {
          ReviewerRow(reviewers: reviewers)
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
              AppOpener.open(remote.createPRURL(sourceBranch: branch, targetBranch: nil))
            }
            .controlSize(.small)
          }
        }
      }
    }
  }
}

private struct ReviewerRow: View {
  var reviewers: [ADOReviewer]

  var body: some View {
    HStack(spacing: 4) {
      ForEach(reviewers) { reviewer in
        ReviewerChip(reviewer: reviewer)
      }
    }
  }
}

private struct ReviewerChip: View {
  var reviewer: ADOReviewer

  var body: some View {
    Text(initials(reviewer.displayName))
      .font(.caption2.weight(.bold))
      .foregroundStyle(.white)
      .frame(width: 24, height: 24)
      .background(color, in: .circle)
      .overlay(alignment: .bottomTrailing) {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(color)
          .padding(1)
          .background(.background, in: .circle)
      }
      .help("\(reviewer.displayName) — \(voteText)")
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

private struct PipelinePill: View {
  var pipeline: WorktreeAzureModel.Pipeline

  var body: some View {
    if pipeline.state != .none {
      Button {
        if let url = pipeline.url { AppOpener.open(url) }
      } label: {
        Label(text, systemImage: icon).font(.caption.weight(.medium))
      }
      .buttonStyle(.plain)
      .foregroundStyle(tint)
      .help("Latest pipeline: \(text)")
    }
  }

  private var text: String {
    switch pipeline.state {
    case .succeeded: return "Passed"
    case .failed: return "Failed"
    case .running: return "Running"
    case .none: return ""
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

// MARK: Work item

private struct WorkItemCard: View {
  var item: ADOWorkItem?
  var id: String?
  var guessed: Bool
  var workItemOrg: String?
  var onConfirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("Work Item", systemImage: "checklist").font(.subheadline.weight(.medium))
        Spacer()
        if let id {
          Button("Open", systemImage: "arrow.up.right.square") {
            if let org = workItemOrg {
              AppOpener.open("https://dev.azure.com/\(org)/_workitems/edit/\(id)")
            }
          }
          .controlSize(.small).labelStyle(.iconOnly)
        }
      }

      if let item {
        HStack(spacing: 6) {
          if let type = item.type { StatusPill(text: type, tint: .purple) }
          if let state = item.state { StatusPill(text: state, tint: .blue) }
          Text("#\(String(item.id))").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        if let title = item.title { Text(title).font(.callout).lineLimit(2) }
      } else if let id {
        Text("#\(id)").font(.callout.monospaced()).foregroundStyle(.secondary)
      }

      if guessed {
        HStack(spacing: 8) {
          Label("Guessed from branch name", systemImage: "questionmark.circle")
            .font(.caption).foregroundStyle(.orange)
          Button("Confirm") { onConfirm() }.controlSize(.mini)
        }
      }
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
