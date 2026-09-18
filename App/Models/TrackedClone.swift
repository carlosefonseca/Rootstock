import Foundation
import SwiftData

/// A git clone the user has chosen to watch. Its worktrees are discovered live
/// from `git`, so only the clone itself is persisted — this is *your* local list
/// of what to watch, never committed anywhere.
@Model
final class TrackedClone {
  /// Absolute path of the shared `.git` common dir — stable identity across worktrees.
  @Attribute(.unique) var commonDir: String
  var displayName: String
  var rootPath: String
  var remoteURL: String?
  var addedAt: Date
  /// Typed into every new terminal tab's shell right after it starts — e.g. a
  /// `nvm use` or a workspace-specific env setup. Local to this machine only,
  /// never written into the repo.
  var terminalInitCommand: String?
  /// Pre-filled as the base branch in the "New Worktree" dialog for this clone.
  /// Local to this machine only — falls back to `develop` when unset.
  var defaultBaseBranch: String?

  init(commonDir: String, displayName: String, rootPath: String, remoteURL: String?) {
    self.commonDir = commonDir
    self.displayName = displayName
    self.rootPath = rootPath
    self.remoteURL = remoteURL
    self.addedAt = .now
  }

  var rootURL: URL { URL(fileURLWithPath: rootPath) }

  /// The configured default base branch, falling back to `develop` when unset or blank.
  var resolvedDefaultBaseBranch: String {
    let trimmed = defaultBaseBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty == false ? trimmed : nil) ?? "develop"
  }
}
