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

  init(commonDir: String, displayName: String, rootPath: String, remoteURL: String?) {
    self.commonDir = commonDir
    self.displayName = displayName
    self.rootPath = rootPath
    self.remoteURL = remoteURL
    self.addedAt = .now
  }

  var rootURL: URL { URL(fileURLWithPath: rootPath) }
}
