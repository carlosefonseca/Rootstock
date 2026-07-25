import SwiftUI

/// Cross-repo pull-request work: PRs to review, PRs waiting on the author that
/// now have resolved threads, comments that got a reply, and the user's own
/// PRs that are failing checks or have conflicts. Opens as its own window (see
/// `RootstockApp`'s "pr-work" `Window` scene) so it can stay open alongside
/// the main window.
struct MyPRWorkView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(CrossRepoPRWorkModel.self) private var model

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Pull Request Work")
        .toolbar {
          ToolbarItem {
            Button("Refresh", systemImage: "arrow.clockwise") { model.refresh(clones: workspace.clones) }
              .disabled(model.phase == .loading)
          }
        }
    }
    .frame(minWidth: 640, minHeight: 440)
    .task { model.refreshIfStale(clones: workspace.clones) }
  }

  @ViewBuilder private var content: some View {
    if model.items.isEmpty {
      switch model.phase {
      case .idle, .loading:
        VStack(spacing: 8) {
          ProgressView()
          Text("Checking pull requests…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ContentUnavailableView {
          Label("Couldn't Load", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Retry") { model.refresh(clones: workspace.clones) }
        }
      case .loaded:
        ContentUnavailableView {
          Label("All Caught Up", systemImage: "checkmark.circle")
        } description: {
          Text("No pull requests need your attention right now.")
        }
      }
    } else {
      List {
        if !model.repoErrors.isEmpty {
          Section {
            ForEach(Array(model.repoErrors.keys)) { repo in
              Label("\(repo.displayName): \(model.repoErrors[repo] ?? "")", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
            }
          }
        }
        ForEach(groupedByRepo, id: \.repo.id) { group in
          Section(group.repo.displayName) {
            ForEach(group.items) { item in PRWorkRow(item: item) }
          }
        }
      }
    }
  }

  private var groupedByRepo: [(repo: RepoRef, items: [PRWork])] {
    Dictionary(grouping: model.items, by: \.repo)
      .map { (repo: $0.key, items: $0.value.sorted { $0.pr.pullRequestId < $1.pr.pullRequestId }) }
      .sorted { $0.repo.displayName < $1.repo.displayName }
  }
}

private struct PRWorkRow: View {
  var item: PRWork

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("#\(item.pr.pullRequestId) — \(item.pr.title)").font(.callout).lineLimit(1)
        Spacer()
        Button("Open", systemImage: "arrow.up.right.square") {
          let remote = AzureRemote(org: item.repo.org, project: item.repo.project, repo: item.repo.repo)
          AppOpener.open(remote.pullRequestURL(id: item.pr.pullRequestId))
        }
        .controlSize(.small).labelStyle(.iconOnly).buttonStyle(.borderless)
      }
      HStack(spacing: 6) {
        if let author = item.author { Text(author.name).font(.caption).foregroundStyle(.secondary) }
        ForEach(item.reasons) { reason in StatusPill(text: reason.detail, tint: tint(reason.kind)) }
      }
      ForEach(previewComments) { comment in
        if let content = comment.content, !content.isEmpty {
          Text(content).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      if hiddenCommentCount > 0 {
        Text("+\(hiddenCommentCount) more").font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
  }

  /// A PR with the same boilerplate comment left on many lines shouldn't turn
  /// into a wall of repeated text — dedupe by content, then cap the count.
  private var uniqueComments: [ADOComment] {
    var seenContent = Set<String>()
    return item.relevantComments.filter { comment in
      guard let content = comment.content else { return false }
      return seenContent.insert(content).inserted
    }
  }
  private var previewComments: [ADOComment] { Array(uniqueComments.prefix(3)) }
  private var hiddenCommentCount: Int { uniqueComments.count - previewComments.count }

  private func tint(_ kind: PRWorkReason.Kind) -> Color {
    switch kind {
    case .needsReview: return .blue
    case .waitingResolved: return .green
    case .hasReplies: return .purple
    case .failingOrConflict: return .red
    }
  }
}
