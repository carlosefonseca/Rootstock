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

  struct Pipeline: Equatable {
    enum State { case succeeded, failed, running, none }
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

  private(set) var phase: Phase = .idle
  private(set) var pr: ADOPullRequest?
  private(set) var unresolved = 0
  private(set) var pipeline = Pipeline(state: .none, url: nil)
  private(set) var workItems: [WorkItemEntry] = []
  /// A work-item link found in the PR description that isn't in the configured
  /// list yet — offered as a "Confirm" suggestion, never added automatically.
  private(set) var detectedWorkItem: WorkItemURL?

  // Held here (not as separate @State on AzureSection) so it's part of the same
  // Observable graph as `phase` and updates in the same transaction — the view
  // was seeing these desync from `phase` when they lived on split @State/
  // @Observable storage.
  private(set) var remote: AzureRemote?

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

    await resolveWorkItems(worktree: worktree, branch: branch, prDescription: pr?.description)

    if remote == nil && workItems.isEmpty && detectedWorkItem == nil {
      phase = .notConfigured
    } else if let prFailure, workItems.isEmpty {
      phase = .failed(prFailure.localizedDescription)
    } else {
      phase = .loaded
    }
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
