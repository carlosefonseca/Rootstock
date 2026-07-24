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
    var label: String? = nil
  }

  private(set) var phase: Phase = .idle
  private(set) var pr: ADOPullRequest?
  private(set) var unresolved = 0
  private(set) var pipeline = Pipeline(state: .none, url: nil)
  private(set) var workItem: ADOWorkItem?
  private(set) var workItemID: String?
  private(set) var workItemGuessed = false

  // The resolved context for the current load, held here (not as separate @State
  // on AzureSection) so it's part of the same Observable graph as `phase` and
  // updates in the same transaction — the view was seeing these desync from
  // `phase`/`workItemID` when they lived on split @State/@Observable storage.
  private(set) var remote: AzureRemote?
  private(set) var workItemOrg: String?
  private(set) var workItemProject: String?

  private let service = AzureService()

  /// Loads everything for `worktree`. `remote` is parsed from the clone's origin;
  /// `workItemOrg`/`workItemProject` come from `.dcdp/config.toml` or the user's
  /// defaults (falling back to the code org).
  ///
  /// Work-item resolution runs independently of the PR/pipeline fetch: the work
  /// item can live in a different org than the code (see the two-org setup), so a
  /// `WORK_ITEM_ID` already recorded in the branch's shared conf should fetch its
  /// details even when the code remote doesn't resolve or the PR call fails.
  func load(worktree: WorktreeInfo, remote: AzureRemote?, workItemOrg: String?, workItemProject: String?) async {
    self.remote = remote
    self.workItemOrg = workItemOrg
    self.workItemProject = workItemProject
    guard let branch = worktree.branch else {
      phase = .notConfigured
      return
    }
    phase = .loading

    var prFailure: Error?
    if let remote {
      do {
        let pull = try await service.pullRequest(remote: remote, branch: branch)
        self.pr = pull
        if let pull {
          async let unresolved = service.unresolvedCommentCount(remote: remote, prId: pull.pullRequestId)
          async let build = service.latestBuild(remote: remote, branch: branch)
          self.unresolved = await unresolved
          self.pipeline = pipeline(from: await build)
        } else {
          self.unresolved = 0
          self.pipeline = pipeline(from: await service.latestBuild(remote: remote, branch: branch))
        }
      } catch {
        prFailure = error
        self.pr = nil
        self.unresolved = 0
        self.pipeline = Pipeline(state: .none, url: nil)
      }
    } else {
      self.pr = nil
      self.unresolved = 0
      self.pipeline = Pipeline(state: .none, url: nil)
    }

    await resolveWorkItem(worktree: worktree, branch: branch, remote: remote,
                          workItemOrg: workItemOrg, workItemProject: workItemProject,
                          prDescription: pr?.description)

    if remote == nil && workItemID == nil {
      phase = .notConfigured
    } else if let prFailure, workItemID == nil {
      phase = .failed(prFailure.localizedDescription)
    } else {
      phase = .loaded
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

  private func resolveWorkItem(worktree: WorktreeInfo, branch: String, remote: AzureRemote?,
                               workItemOrg: String?, workItemProject: String?, prDescription: String?) async {
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

    guard let org = workItemOrg ?? remote?.org else {
      workItem = nil
      return
    }
    workItem = try? await service.workItem(org: org, project: workItemProject, id: resolution.id)
  }

  /// The latest pipeline build for the branch — always carries a working link
  /// when a build exists, unlike PR-level statuses which aren't guaranteed one.
  private func pipeline(from build: ADOBuild?) -> Pipeline {
    guard let build else { return Pipeline(state: .none, url: nil, label: nil) }
    let label = "Build #\(build.buildNumber ?? String(build.id))"
    if build.status != "completed" { return Pipeline(state: .running, url: build.webURL, label: label) }
    switch build.result {
    case "succeeded", "partiallySucceeded": return Pipeline(state: .succeeded, url: build.webURL, label: label)
    case "failed", "canceled": return Pipeline(state: .failed, url: build.webURL, label: label)
    default: return Pipeline(state: .none, url: build.webURL, label: label)
    }
  }
}
