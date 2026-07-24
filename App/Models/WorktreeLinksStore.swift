import Foundation
import Observation

/// Caches the resolved pull-request URL per worktree so the tab bar's "+" menu
/// can offer a quick link without re-running Azure DevOps's PR lookup —
/// `AzureSection` already does that async lookup and just reports the result
/// here. Work item / Figma / Slack links don't need caching: they resolve
/// synchronously from the branch's shared config.
@Observable
@MainActor
final class WorktreeLinksStore {
  private(set) var pullRequestURLs: [String: String] = [:]

  func pullRequestURL(for worktree: WorktreeInfo) -> String? {
    pullRequestURLs[worktree.path]
  }

  func setPullRequestURL(_ url: String?, for worktree: WorktreeInfo) {
    pullRequestURLs[worktree.path] = url
  }
}
