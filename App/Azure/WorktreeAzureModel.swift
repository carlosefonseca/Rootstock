import Foundation
import Observation

/// Loads and holds the Azure DevOps picture for one worktree: its PR, pipeline
/// status, and work items. Created per worktree by `AzureSection`.
@Observable
@MainActor
final class WorktreeAzureModel {
  enum Phase: Equatable {
    case notConfigured        // remote isn't an ADO repo, and no work items configured
    case idle                 // configured, not loaded yet
    case loading
    case loaded
    case failed(String)
  }

  /// The latest build for one pipeline definition (e.g. "ios-build",
  /// "ios-test") that ran against this branch or PR.
  struct Pipeline: Equatable, Identifiable {
    enum State { case succeeded, failed, running, none }
    /// Whether this pipeline's latest run was the PR's actual validation
    /// build (`refs/pull/<id>/merge`) or just a plain branch-push build
    /// (`refs/heads/<branch>`) — the two aren't always the same build.
    enum Source { case pullRequest, branch }
    var id: Int
    var name: String
    var source: Source
    var state: State
    var url: String?
    var label: String? = nil
  }

  /// One configured work item, with its fetched detail once available. `detail`
  /// stays nil (not an error state) while the fetch is in flight or if it fails
  /// — the id/org/project from the URL are enough to show something useful.
  struct WorkItemEntry: Identifiable {
    var url: WorkItemURL
    var detail: ADOWorkItem?
    var id: String { url.canonical }
  }

  /// One manually-attached PR beyond the branch's auto-detected one — e.g. the
  /// work was split across several PRs. `pr` stays nil (not an error state)
  /// while the fetch is in flight or if it fails — the id/org/project/repo
  /// from the URL are enough to show something useful.
  struct AdditionalPREntry: Identifiable {
    var url: PullRequestURL
    var pr: ADOPullRequest?
    var id: String { url.canonical }
  }

  private(set) var phase: Phase = .idle
  private(set) var pr: ADOPullRequest?
  private(set) var unresolved = 0
  private(set) var pipelines: [Pipeline] = []
  /// Definition ids with a queue request in flight, so the pill can show a
  /// spinner instead of letting the user queue the same pipeline twice.
  private(set) var queueingPipelines: Set<Int> = []
  /// Why the last manual queue failed, if it did — most often a permissions
  /// problem (a PAT without Build: Read & execute), which is worth showing
  /// rather than swallowing.
  private(set) var queueError: String?
  /// True while a load is in flight over content that's already on screen, so
  /// the header can show a spinner without the section blanking itself out.
  private(set) var isReloading = false
  /// A refresh that failed while there was still good data to show — reported
  /// alongside the stale content instead of replacing it with `.failed`.
  private(set) var reloadError: String?
  private(set) var workItems: [WorkItemEntry] = []
  private(set) var additionalPRs: [AdditionalPREntry] = []
  /// A work-item link found in the PR description that isn't in the configured
  /// list yet — offered as a "Confirm" suggestion, never added automatically.
  private(set) var detectedWorkItem: WorkItemURL?

  // Held here (not as separate @State on AzureSection) so it's part of the same
  // Observable graph as `phase` and updates in the same transaction — the view
  // was seeing these desync from `phase` when they lived on split @State/
  // @Observable storage.
  private(set) var remote: AzureRemote?

  /// Which worktree the currently-held content belongs to. The section's view —
  /// and so this model — survives a switch between worktrees, and last
  /// worktree's PR must not linger under the new one's heading while it loads.
  private var loadedWorktreePath: String?

  private let service = AzureService()

  /// Loads everything for `worktree`. `remote` is parsed from the clone's
  /// origin. Work items are entirely self-describing via their URLs (org,
  /// project, and id all come from the URL itself), so unlike the PR/pipeline
  /// fetch, resolving them doesn't depend on `remote` being set at all — a
  /// repo that isn't recognized as an Azure DevOps code remote can still list
  /// and fetch work items configured for the branch.
  func load(worktree: WorktreeInfo, remote: AzureRemote?) async {
    self.remote = remote
    guard let branch = worktree.branch else {
      phase = .notConfigured
      return
    }

    // A reload over content that's already up shouldn't tear it down: the new
    // values land field by field as they arrive, and until then the previous
    // ones stay readable. Only a first load — or a switch to a different
    // worktree, whose data this is not — goes through the empty `.loading`
    // state.
    let isSameWorktree = loadedWorktreePath == worktree.path
    if !isSameWorktree { clearContent() }
    let showingContent = phase == .loaded && isSameWorktree
    if !showingContent { phase = .loading }
    loadedWorktreePath = worktree.path
    isReloading = true
    reloadError = nil
    defer { isReloading = false }

    var prFailure: Error?
    if let remote {
      do {
        let pull = try await service.pullRequest(remote: remote, branch: branch)
        self.pr = pull
        if let pull {
          async let unresolved = service.unresolvedCommentCount(remote: remote, prId: pull.pullRequestId)
          async let builds = service.latestBuildsByPipeline(remote: remote, branch: branch, prId: pull.pullRequestId)
          self.unresolved = await unresolved
          self.pipelines = pipelines(from: await builds)
        } else {
          self.unresolved = 0
          self.pipelines = pipelines(from: await service.latestBuildsByPipeline(remote: remote, branch: branch, prId: nil))
        }
      } catch {
        prFailure = error
        // Keep whatever was already on screen when a refresh fails — a dropped
        // network or an expired session shouldn't cost the user the PR they
        // were looking at. There's nothing to keep on a first load.
        if !showingContent {
          self.pr = nil
          self.unresolved = 0
          self.pipelines = []
        }
      }
    } else {
      self.pr = nil
      self.unresolved = 0
      self.pipelines = []
    }

    await resolveWorkItems(worktree: worktree, branch: branch, prDescription: pr?.description)
    await resolveAdditionalPRs(worktree: worktree, branch: branch)

    if remote == nil && workItems.isEmpty && detectedWorkItem == nil && additionalPRs.isEmpty {
      phase = .notConfigured
    } else if let prFailure, workItems.isEmpty, !showingContent {
      phase = .failed(prFailure.localizedDescription)
    } else {
      phase = .loaded
      reloadError = prFailure?.localizedDescription
    }
  }

  func clearReloadError() { reloadError = nil }

  private func clearContent() {
    pr = nil
    unresolved = 0
    pipelines = []
    workItems = []
    additionalPRs = []
    detectedWorkItem = nil
    reloadError = nil
    queueError = nil
  }

  /// Adds the detected suggestion to the branch's shared config and re-fetches.
  func confirmDetectedWorkItem(worktree: WorktreeInfo, branch: String) {
    guard let detected = detectedWorkItem else { return }
    var config = BranchConfig.load(worktree: worktree.url, branch: branch)
    if !config.workItemURLs.contains(detected.canonical) {
      config.workItemURLs.append(detected.canonical)
      try? config.save(worktree: worktree.url, branch: branch)
    }
    detectedWorkItem = nil
    NotificationCenter.default.post(name: .branchConfigChanged, object: nil)
  }

  /// Removes a configured work item from the branch's shared config and re-fetches.
  func removeWorkItem(worktree: WorktreeInfo, branch: String, url: WorkItemURL) {
    var config = BranchConfig.load(worktree: worktree.url, branch: branch)
    config.workItemURLs.removeAll { $0 == url.canonical }
    try? config.save(worktree: worktree.url, branch: branch)
    NotificationCenter.default.post(name: .branchConfigChanged, object: nil)
  }

  /// Triggers a fresh run of `pipeline` and refreshes the pipeline list so the
  /// pill flips to "Running" without waiting for the next full reload.
  ///
  /// Two different things can be meant by "run this again", and which one
  /// happens matters:
  ///
  /// - When this pipeline is a *build validation policy* on the PR (the common
  ///   case for an optional check), the policy evaluation is requeued — the
  ///   same call the PR page's "Queue" link makes, so the PR's own check entry
  ///   goes back to running and records the result.
  /// - Otherwise the build is queued directly, against the PR's merge ref if
  ///   there is a PR (matching how a validation build runs) or the branch tip
  ///   if there isn't. That produces a real build but no PR check entry.
  func runPipeline(_ pipeline: Pipeline, branch: String) async {
    guard let remote, !queueingPipelines.contains(pipeline.id) else { return }
    let prId = pr?.pullRequestId

    queueingPipelines.insert(pipeline.id)
    queueError = nil
    defer { queueingPipelines.remove(pipeline.id) }
    do {
      if let prId, let evaluationId = await policyEvaluation(forDefinition: pipeline.id, remote: remote, prId: prId) {
        try await service.requeuePolicyEvaluation(remote: remote, evaluationId: evaluationId)
      } else {
        let sourceRef = prId.map { "refs/pull/\($0)/merge" } ?? "refs/heads/\(branch)"
        _ = try await service.queueBuild(remote: remote, definitionId: pipeline.id, sourceRef: sourceRef)
      }
      let builds = await service.latestBuildsByPipeline(remote: remote, branch: branch, prId: prId)
      pipelines = pipelines(from: builds)
    } catch {
      queueError = error.localizedDescription
    }
  }

  /// The PR's policy evaluation driven by this build definition, if the pipeline
  /// is wired up as a branch policy at all. Fetched on demand rather than during
  /// `load` — it costs two extra requests and only matters when the user
  /// actually triggers something.
  private func policyEvaluation(forDefinition definitionId: Int, remote: AzureRemote, prId: Int) async -> String? {
    guard let projectId = try? await service.projectId(remote: remote) else { return nil }
    let evaluations = await service.policyEvaluations(remote: remote, projectId: projectId, prId: prId)
    return evaluations.first { $0.buildDefinitionId == definitionId }?.evaluationId
  }

  func clearQueueError() { queueError = nil }

  /// Removes a manually-attached PR from the branch's shared config and re-fetches.
  func removeAdditionalPR(worktree: WorktreeInfo, branch: String, url: PullRequestURL) {
    var config = BranchConfig.load(worktree: worktree.url, branch: branch)
    config.additionalPRURLs.removeAll { $0 == url.canonical }
    try? config.save(worktree: worktree.url, branch: branch)
    NotificationCenter.default.post(name: .branchConfigChanged, object: nil)
  }

  private func resolveWorkItems(worktree: WorktreeInfo, branch: String, prDescription: String?) async {
    let config = BranchConfig.load(worktree: worktree.url, branch: branch)
    let configured = config.workItemURLs.compactMap { WorkItemURL.parse($0) }
    for wiURL in configured { AzureSettingsStore.addManualOrg(wiURL.org) }

    workItems = await withTaskGroup(of: WorkItemEntry.self) { group in
      for wiURL in configured {
        group.addTask {
          let detail = try? await self.service.workItem(org: wiURL.org, project: wiURL.project, id: wiURL.id)
          return WorkItemEntry(url: wiURL, detail: detail)
        }
      }
      var results: [WorkItemEntry] = []
      for await entry in group { results.append(entry) }
      return results
    }
    // withTaskGroup doesn't preserve submission order.
    workItems.sort { configured.firstIndex(of: $0.url) ?? 0 < configured.firstIndex(of: $1.url) ?? 0 }

    detectedWorkItem = WorkItemResolver.detect(in: prDescription, excluding: configured)
  }

  private func resolveAdditionalPRs(worktree: WorktreeInfo, branch: String) async {
    let config = BranchConfig.load(worktree: worktree.url, branch: branch)
    let configured = config.additionalPRURLs.compactMap { PullRequestURL.parse($0) }
    for prURL in configured { AzureSettingsStore.addManualOrg(prURL.org) }

    additionalPRs = await withTaskGroup(of: AdditionalPREntry.self) { group in
      for prURL in configured {
        group.addTask {
          let remote = AzureRemote(org: prURL.org, project: prURL.project, repo: prURL.repo)
          let pull = try? await self.service.pullRequest(remote: remote, id: prURL.id)
          return AdditionalPREntry(url: prURL, pr: pull)
        }
      }
      var results: [AdditionalPREntry] = []
      for await entry in group { results.append(entry) }
      return results
    }
    // withTaskGroup doesn't preserve submission order.
    additionalPRs.sort { configured.firstIndex(of: $0.url) ?? 0 < configured.firstIndex(of: $1.url) ?? 0 }
  }

  /// Converts each pipeline definition's latest build into a `Pipeline`,
  /// sorted by name so the list stays stable across reloads rather than
  /// jumping around by recency.
  private func pipelines(from builds: [(build: ADOBuild, source: AzureService.BuildSource)]) -> [Pipeline] {
    builds.compactMap { entry -> Pipeline? in
      guard let definitionId = entry.build.definition?.id else { return nil }
      let build = entry.build
      let label = "#\(build.buildNumber ?? String(build.id))"
      let source: Pipeline.Source = entry.source == .pullRequest ? .pullRequest : .branch
      let state: Pipeline.State
      if build.status != "completed" {
        state = .running
      } else {
        switch build.result {
        case "succeeded", "partiallySucceeded": state = .succeeded
        case "failed", "canceled": state = .failed
        default: state = .none
        }
      }
      return Pipeline(id: definitionId, name: build.definition?.name ?? "Pipeline", source: source,
                       state: state, url: build.webURL, label: label)
    }.sorted { $0.name < $1.name }
  }
}
