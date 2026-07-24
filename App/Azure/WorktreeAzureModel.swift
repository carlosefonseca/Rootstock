import Foundation
import Observation

/// Loads and holds the Azure DevOps picture for one worktree: its PR, pipeline
/// status, and work item. Created per worktree by `AzureSection`.
@Observable
@MainActor
final class WorktreeAzureModel {
  enum Phase: Equatable {
    case notConfigured        // remote isn't an ADO repo
    case idle                 // configured, not loaded yet
    case loading
    case loaded
    case failed(String)
  }

  struct Pipeline: Equatable {
    enum State { case succeeded, failed, running, none }
    var state: State
    var url: String?
  }

  private(set) var phase: Phase = .idle
  private(set) var pr: ADOPullRequest?
  private(set) var unresolved = 0
  private(set) var pipeline = Pipeline(state: .none, url: nil)
  private(set) var workItem: ADOWorkItem?
  private(set) var workItemID: String?
  private(set) var workItemGuessed = false

  private let service = AzureService()

  /// Loads everything for `worktree`. `remote` is parsed from the clone's origin;
  /// `workItemOrg` comes from `.dcdp/config.toml` (falling back to the code org).
  func load(worktree: WorktreeInfo, remote: AzureRemote?, workItemOrg: String?) async {
    guard let remote, let branch = worktree.branch else {
      phase = .notConfigured
      return
    }
    phase = .loading
    do {
      let pull = try await service.pullRequest(remote: remote, branch: branch)
      self.pr = pull

      if let pull {
        async let unresolved = service.unresolvedCommentCount(remote: remote, prId: pull.pullRequestId)
        async let statuses = service.prStatuses(remote: remote, prId: pull.pullRequestId)
        async let build = service.latestBuild(remote: remote, branch: branch)
        self.unresolved = await unresolved
        self.pipeline = pipeline(from: await statuses, build: await build)
      } else {
        self.unresolved = 0
        self.pipeline = pipeline(from: [], build: await service.latestBuild(remote: remote, branch: branch))
      }

      await resolveWorkItem(worktree: worktree, branch: branch,
                            remote: remote, workItemOrg: workItemOrg, prDescription: pull?.description)
      phase = .loaded
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// Writes the resolved id into the shared conf, promoting a guess to confirmed.
  func confirmWorkItem(worktree: WorktreeInfo, branch: String) {
    guard let id = workItemID else { return }
    var config = BranchConfig.load(worktree: worktree.url, branch: branch)
    config.workItemID = id
    try? config.save(worktree: worktree.url, branch: branch)
    workItemGuessed = false
  }

  private func resolveWorkItem(worktree: WorktreeInfo, branch: String, remote: AzureRemote,
                               workItemOrg: String?, prDescription: String?) async {
    let config = BranchConfig.load(worktree: worktree.url, branch: branch)
    guard let resolution = WorkItemResolver.resolve(
      config: config, branch: branch, prDescription: prDescription) else {
      workItem = nil; workItemID = nil; workItemGuessed = false
      return
    }
    workItemID = resolution.id
    workItemGuessed = resolution.guessed

    // A confident (non-guessed) resolution from the PR description is written back
    // so detection runs at most once per branch.
    if !resolution.guessed, config.workItemID == nil {
      var updated = config
      updated.workItemID = resolution.id
      try? updated.save(worktree: worktree.url, branch: branch)
    }

    let org = workItemOrg ?? remote.org
    workItem = try? await service.workItem(org: org, id: resolution.id)
  }

  private func pipeline(from statuses: [ADOPRStatus], build: ADOBuild?) -> Pipeline {
    // Prefer PR build-validation statuses when present.
    if !statuses.isEmpty {
      let states = statuses.compactMap { $0.state?.lowercased() }
      let url = statuses.first?.targetUrl
      if states.contains("failed") || states.contains("error") { return Pipeline(state: .failed, url: url) }
      if states.contains("pending") { return Pipeline(state: .running, url: url) }
      if states.allSatisfy({ $0 == "succeeded" || $0 == "notapplicable" }) { return Pipeline(state: .succeeded, url: url) }
    }
    guard let build else { return Pipeline(state: .none, url: nil) }
    if build.status != "completed" { return Pipeline(state: .running, url: build.webURL) }
    switch build.result {
    case "succeeded", "partiallySucceeded": return Pipeline(state: .succeeded, url: build.webURL)
    case "failed", "canceled": return Pipeline(state: .failed, url: build.webURL)
    default: return Pipeline(state: .none, url: build.webURL)
    }
  }
}
