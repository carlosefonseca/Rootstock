import Foundation

/// Attaches a work item or an extra pull request to a branch's shared config.
/// Three routes reach the same write — the "Add Work Item"/"Add Pull Request"
/// popovers, the shared-config editor, and right-clicking an Azure DevOps link
/// inside a web tab — so the dedupe-and-notify behaviour lives here rather than
/// being re-derived at each call site.
enum BranchLinkAttachment {
  /// Returns false when the URL was already attached, so a caller can tell the
  /// difference between "added" and "nothing to do".
  @discardableResult
  static func attach(workItem url: WorkItemURL, worktree: URL, branch: String) -> Bool {
    var config = BranchConfig.load(worktree: worktree, branch: branch)
    let isNew = !config.workItemURLs.contains(url.canonical)
    if isNew {
      config.workItemURLs.append(url.canonical)
      try? config.save(worktree: worktree, branch: branch)
    }
    NotificationCenter.default.post(name: .branchConfigChanged, object: nil)
    return isNew
  }

  @discardableResult
  static func attach(pullRequest url: PullRequestURL, worktree: URL, branch: String) -> Bool {
    var config = BranchConfig.load(worktree: worktree, branch: branch)
    let isNew = !config.additionalPRURLs.contains(url.canonical)
    if isNew {
      config.additionalPRURLs.append(url.canonical)
      try? config.save(worktree: worktree, branch: branch)
    }
    NotificationCenter.default.post(name: .branchConfigChanged, object: nil)
    return isNew
  }
}
