import Foundation
import Observation

/// A user-defined shell command shown in a worktree's "Custom Actions" card.
struct CustomAction: Identifiable, Codable, Hashable {
  var id = UUID()
  var name: String
  var command: String
}

/// App-lifetime owner of every worktree's custom actions, persisted to
/// UserDefaults keyed by worktree path. Actions belong to a worktree, but the
/// store can read across all of them so the editor can offer to copy one from a
/// sibling worktree instead of retyping it.
@Observable
@MainActor
final class CustomActionsStore {
  private var actionsByWorktree: [String: [CustomAction]]

  private static let storageKey = "customActions.v1"

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
       let decoded = try? JSONDecoder().decode([String: [CustomAction]].self, from: data) {
      actionsByWorktree = decoded
    } else {
      actionsByWorktree = [:]
    }
  }

  func actions(for worktree: WorktreeInfo) -> [CustomAction] {
    actionsByWorktree[worktree.path] ?? []
  }

  func add(_ action: CustomAction, to worktree: WorktreeInfo) {
    actionsByWorktree[worktree.path, default: []].append(action)
    persist()
  }

  func update(_ action: CustomAction, in worktree: WorktreeInfo) {
    guard let index = actionsByWorktree[worktree.path]?.firstIndex(where: { $0.id == action.id }) else { return }
    actionsByWorktree[worktree.path]?[index] = action
    persist()
  }

  func remove(_ action: CustomAction, from worktree: WorktreeInfo) {
    actionsByWorktree[worktree.path]?.removeAll { $0.id == action.id }
    persist()
  }

  /// Forgets a deleted worktree's actions.
  func removeAll(for worktree: WorktreeInfo) {
    actionsByWorktree[worktree.path] = nil
    persist()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(actionsByWorktree) else { return }
    UserDefaults.standard.set(data, forKey: Self.storageKey)
  }
}
