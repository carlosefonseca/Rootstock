import Foundation
import SwiftData

/// Free-text scratch notes for a branch. Personal and local-only — the one thing
/// that deliberately never becomes a repo file.
@Model
final class BranchNotes {
  /// "<commonDir>|<branch>" — unique per branch within a clone.
  @Attribute(.unique) var key: String
  var text: String
  var updatedAt: Date

  init(key: String, text: String = "") {
    self.key = key
    self.text = text
    self.updatedAt = .now
  }

  static func key(commonDir: String, branch: String) -> String {
    "\(commonDir)|\(branch)"
  }
}
