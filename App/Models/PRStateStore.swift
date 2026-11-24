import Observation
import SwiftUI

/// The last-seen pull request state ("active" / "completed" / "abandoned") per
/// worktree, so the sidebar can mark finished worktrees without loading Azure
/// DevOps for each one. Updated whenever a worktree's Azure section loads.
@Observable
@MainActor
final class PRStateStore {
  private static let key = "prStates.v1"
  private var states: [String: String]

  init() {
    states = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
  }

  func state(for worktree: WorktreeInfo) -> String? { states[worktree.path] }

  func set(_ state: String?, for worktree: WorktreeInfo) {
    guard states[worktree.path] != state else { return }
    states[worktree.path] = state
    UserDefaults.standard.set(states, forKey: Self.key)
  }

  static func tint(for pr: ADOPullRequest) -> Color {
    if pr.status == "completed" { return .purple }
    if pr.status == "abandoned" { return .secondary }
    return (pr.isDraft ?? false) ? .secondary : .blue
  }
}
