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
        // The spinner replaces the button in place rather than sitting beside
        // it, so the header doesn't reflow every time something refreshes.
        if model.isReloading {
          ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 18)
        } else {
          Button("Reload", systemImage: "arrow.clockwise") { startReload() }
            .controlSize(.small).labelStyle(.iconOnly).buttonStyle(.borderless)
        }
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

  @ViewBuilder private var pullRequestsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Pull Requests", systemImage: "arrow.triangle.pull").font(.subheadline.weight(.medium))
        Spacer()
        if let branch = worktree.branch {
          AddPullRequestButton(worktree: worktree, branch: branch)
        }
      }
      // The branch's own auto-detected PR always leads the list, tagged with
      // a "Branch" badge — everything else is manually attached, in the order
      // it was added.
      BranchPRRow(pr: model.pr, unresolved: model.unresolved, pipelines: model.pipelines, remote: model.remote,
                  branch: worktree.branch, worktree: worktree, tabsStore: tabsStore,
                  queueing: model.queueingPipelines,
                  onRun: { pipeline in
                    guard let branch = worktree.branch else { return }
                    Task { await model.runPipeline(pipeline, branch: branch) }
                  })
      if let queueError = model.queueError {
        InlineErrorLine(message: queueError) { model.clearQueueError() }
      }
      ForEach(model.additionalPRs) { entry in
        AdditionalPRCard(entry: entry, worktree: worktree, tabsStore: tabsStore) {
          if let branch = worktree.branch {
            model.removeAdditionalPR(worktree: worktree, branch: branch, url: entry.url)
          }
        }
      }
    }
  }

  @ViewBuilder private var loadedContent: some View {
    if let reloadError = model.reloadError {
      InlineErrorLine(message: reloadError) { model.clearReloadError() }
    }
    pullRequestsSection
    if let branch = worktree.branch {
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("Work Items", systemImage: "checklist").font(.subheadline.weight(.medium))
          Spacer()
          AddWorkItemButton(worktree: worktree, branch: branch)
        }
        ForEach(model.workItems) { entry in
          WorkItemCard(entry: entry, worktree: worktree, tabsStore: tabsStore) {
            model.removeWorkItem(worktree: worktree, branch: branch, url: entry.url)
          }
        }
        if let detected = model.detectedWorkItem {
          DetectedWorkItemRow(url: detected) {
            model.confirmDetectedWorkItem(worktree: worktree, branch: branch)
          }
        }
      }
    }
  }
}

/// A dismissible one-line problem report that sits next to the content it's
/// about, for failures the section can survive — a refresh that didn't land, a
/// pipeline that wouldn't queue — as opposed to `.failed`, which replaces
/// everything.
private struct InlineErrorLine: View {
  var message: String
  var onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.orange)
      Spacer(minLength: 0)
      Button("Dismiss", action: onDismiss)
        .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
    }
  }
}

// MARK: Pull request

/// The branch's own auto-detected PR (matched by source branch name) — always
/// the first row in the merged pull-requests list, distinguished from
/// manually-attached ones by the "Branch" badge.
private struct BranchPRRow: View {
  var pr: ADOPullRequest?
  var unresolved: Int
  var pipelines: [WorktreeAzureModel.Pipeline]
  var remote: AzureRemote?
  var branch: String?
  var worktree: WorktreeInfo
  var tabsStore: WorktreeTabsStore
  var queueing: Set<Int>
  var onRun: (WorktreeAzureModel.Pipeline) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let pr {
        // Nested rather than inlined into the outer stack purely so the context
        // menu covers this whole row and nothing else — the empty "No active
        // pull request" state below has nothing to copy.
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            StatusPill(text: "Branch", tint: .indigo)
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
            Menu {
              menuItems(for: pr)
            } label: {
              Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
          }
          Text(pr.title).font(.callout).lineLimit(2)

          if !pipelines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(pipelines) { pipeline in
                PipelinePill(pipeline: pipeline, worktree: worktree, tabsStore: tabsStore,
                             runsOnPR: true,
                             isQueueing: queueing.contains(pipeline.id),
                             onRun: { onRun(pipeline) })
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
        }
        .contentShape(.rect)
        .contextMenu { menuItems(for: pr) }
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
              PipelinePill(pipeline: pipeline, worktree: worktree, tabsStore: tabsStore,
                           runsOnPR: false,
                           isQueueing: queueing.contains(pipeline.id),
                           onRun: { onRun(pipeline) })
            }
          }
        }
      }
    }
  }

  /// Shared by the row's context menu and its "…" button, so right-clicking
  /// and clicking offer the same thing — as in the attached-PR and work item
  /// rows. No Remove here: this PR is detected from the branch name, not
  /// attached by hand.
  @ViewBuilder private func menuItems(for pr: ADOPullRequest) -> some View {
    if let remote {
      Button("Copy URL") { copy(remote.pullRequestURL(id: pr.pullRequestId)) }
    }
    Button("Copy ID") { copy(String(pr.pullRequestId)) }
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
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
          .font(.system(size: 7, weight: .black))
          .foregroundStyle(.white)
          .frame(width: 12, height: 12)
          .background(color, in: .circle)
          // A ring in the panel color keeps the badge from blending into
          // whatever the avatar happens to have behind it.
          .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
          .offset(x: 2, y: 2)
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
  /// Whether triggering a run will queue against the PR's merge ref — decided
  /// by the model (it always prefers the PR when there is one), so the title
  /// can say which, rather than guessing from this pill's last run.
  var runsOnPR: Bool
  var isQueueing: Bool
  var onRun: () -> Void

  var body: some View {
    // The run control is a sibling of the pill button rather than nested inside
    // its label — a Button inside a Button is a hit-testing coin flip on macOS,
    // and the pill's trailing Spacer already leaves it pinned to the edge.
    HStack(spacing: 4) {
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

      if isQueueing {
        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16)
      } else {
        Button(runTitle, systemImage: "play.circle") { onRun() }
          .buttonStyle(.plain)
          .labelStyle(.iconOnly)
          .font(.caption)
          .foregroundStyle(.tint)
          .help(runTitle)
      }
    }
    .contextMenu {
      Button(runTitle) { onRun() }
        .disabled(isQueueing)
      Divider()
      Button("Copy Name") { copy(pipeline.name) }
      if let label = pipeline.label {
        Button("Copy Build Number") { copy(label) }
      }
      if let url = pipeline.url {
        Button("Copy URL") { copy(url) }
      }
    }
  }

  private var runTitle: String {
    runsOnPR ? "Run on Pull Request" : "Run on Branch"
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
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
  var onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Group {
          if let pr = entry.pr {
            StatusPill(text: (pr.isDraft ?? false) ? "Draft" : pr.status.capitalized,
                       tint: (pr.isDraft ?? false) ? .secondary : .blue)
            if pr.mergeStatus == "conflicts" { StatusPill(text: "Conflicts", tint: .red) }
          }
          // String(_:), not raw Int interpolation — Text(_:) parses an
          // interpolated Int through LocalizedStringKey's number formatting,
          // which inserts a locale thousands separator for values >= 1000.
          Text("#\(String(entry.url.id))").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Open", systemImage: "arrow.up.right.square") {
          WebLinkOpener.open(entry.url.canonical, title: "PR #\(entry.url.id)",
                             systemImage: "arrow.triangle.pull", worktree: worktree, tabsStore: tabsStore)
        }
        .controlSize(.small).labelStyle(.iconOnly)
        Menu {
          menuItems
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      if let title = entry.pr?.title { Text(title).font(.callout).lineLimit(2) }
    }
    .contentShape(.rect)
    .contextMenu { menuItems }
  }

  @ViewBuilder private var menuItems: some View {
    Button("Copy URL") { copy(entry.url.canonical) }
    Button("Copy ID") { copy(String(entry.url.id)) }
    Divider()
    Button("Remove", role: .destructive) { onRemove() }
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }
}

/// Popover to paste a PR URL and attach it to the branch's shared config —
/// mirrors `AddWorkItemButton`, for the common case of linking one more PR
/// (e.g. the work was split across several) without opening the full sheet.
private struct AddPullRequestButton: View {
  var worktree: WorktreeInfo
  var branch: String

  @State private var showingPopover = false
  @State private var urlText = ""
  @State private var error: String?
  @FocusState private var fieldFocused: Bool

  var body: some View {
    Button("Add Pull Request", systemImage: "plus.circle") { showingPopover = true }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .controlSize(.small)
      .popover(isPresented: $showingPopover) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Add Pull Request").font(.headline)
          TextField("Pull request URL", text: $urlText,
                     prompt: Text("https://dev.azure.com/org/project/_git/repo/pullrequest/12345"))
            .textFieldStyle(.roundedBorder)
            .frame(width: 320)
            .focused($fieldFocused)
            .onSubmit { add() }
          if let error {
            Text(error).font(.caption).foregroundStyle(.red)
          }
          HStack {
            Spacer()
            Button("Cancel") { showingPopover = false }
            Button("Add") { add() }
              .keyboardShortcut(.defaultAction)
              .disabled(urlText.isEmpty)
          }
        }
        .padding(16)
        .onAppear { fieldFocused = true }
      }
  }

  private func add() {
    guard let parsed = PullRequestURL.parse(urlText) else {
      error = "Not a recognized pull request URL"
      return
    }
    BranchLinkAttachment.attach(pullRequest: parsed, worktree: worktree.url, branch: branch)
    urlText = ""
    error = nil
    showingPopover = false
  }
}

// MARK: Work item

private struct WorkItemCard: View {
  var entry: WorktreeAzureModel.WorkItemEntry
  var worktree: WorktreeInfo
  var tabsStore: WorktreeTabsStore
  var onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Group {
          if let item = entry.detail {
            HStack(spacing: 6) {
              if let type = item.type { StatusPill(text: type, tint: .purple) }
              if let state = item.state { StatusPill(text: state, tint: .blue) }
              Text("#\(entry.url.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
          } else {
            Text("#\(entry.url.id)").font(.callout.monospaced()).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button("Open", systemImage: "arrow.up.right.square") {
          WebLinkOpener.open(entry.url.canonical, title: "Work Item #\(entry.url.id)",
                             systemImage: "checklist", worktree: worktree, tabsStore: tabsStore)
        }
        .controlSize(.small).labelStyle(.iconOnly)
        Menu {
          menuItems
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      if let title = entry.detail?.title { Text(title).font(.callout).lineLimit(2) }
    }
    .contentShape(.rect)
    .contextMenu { menuItems }
  }

  /// The work item's ID is already a string in the URL, so no `String(_:)`
  /// dance is needed here the way it is for the Int-keyed PR rows.
  @ViewBuilder private var menuItems: some View {
    Button("Copy URL") { copy(entry.url.canonical) }
    Button("Copy ID") { copy(entry.url.id) }
    Divider()
    Button("Remove", role: .destructive) { onRemove() }
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }
}

/// Popover to paste a work item URL and add it to the branch's shared config —
/// mirrors `SharedConfigEditor`'s list editor but reachable without opening
/// the full sheet, for the common case of adding just one.
private struct AddWorkItemButton: View {
  var worktree: WorktreeInfo
  var branch: String

  @State private var showingPopover = false
  @State private var urlText = ""
  @State private var error: String?
  @FocusState private var fieldFocused: Bool

  var body: some View {
    Button("Add Work Item", systemImage: "plus.circle") { showingPopover = true }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .controlSize(.small)
      .popover(isPresented: $showingPopover) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Add Work Item").font(.headline)
          TextField("Work item URL", text: $urlText,
                     prompt: Text("https://dev.azure.com/org/project/_workitems/edit/12345"))
            .textFieldStyle(.roundedBorder)
            .frame(width: 320)
            .focused($fieldFocused)
            .onSubmit { add() }
          if let error {
            Text(error).font(.caption).foregroundStyle(.red)
          }
          HStack {
            Spacer()
            Button("Cancel") { showingPopover = false }
            Button("Add") { add() }
              .keyboardShortcut(.defaultAction)
              .disabled(urlText.isEmpty)
          }
        }
        .padding(16)
        .onAppear { fieldFocused = true }
      }
  }

  private func add() {
    guard let parsed = WorkItemURL.parse(urlText) else {
      error = "Not a recognized work item URL"
      return
    }
    BranchLinkAttachment.attach(workItem: parsed, worktree: worktree.url, branch: branch)
    urlText = ""
    error = nil
    showingPopover = false
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
