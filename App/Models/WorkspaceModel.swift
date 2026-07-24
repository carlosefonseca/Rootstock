import Foundation
import Observation
import SwiftData

/// Central state: the tracked clones, their live-discovered worktrees, and cached
/// status per worktree. Owns discovery and refresh so views stay declarative.
@Observable
@MainActor
final class WorkspaceModel {
  private(set) var clones: [TrackedClone] = []
  /// Worktrees per clone, keyed by clone `commonDir`.
  private(set) var worktrees: [String: [WorktreeInfo]] = [:]
  /// Status per worktree, keyed by worktree path.
  private(set) var statuses: [String: WorktreeStatus] = [:]
  private(set) var lastFetch: [String: Date] = [:]
  private(set) var refreshing = false

  /// Persisted so the same worktree is showing (and its Azure/status data
  /// re-fetched fresh from disk) the next time the app launches, instead of
  /// starting on an empty detail pane every time.
  var selectedPath: String? {
    didSet { UserDefaults.standard.set(selectedPath, forKey: Self.selectedPathKey) }
  }
  private static let selectedPathKey = "workspace.selectedPath"

  @ObservationIgnored private var context: ModelContext?

  init() {
    selectedPath = UserDefaults.standard.string(forKey: Self.selectedPathKey)
  }

  func configure(_ context: ModelContext) {
    guard self.context == nil else { return }
    self.context = context
    reloadClones()
    Task { await refreshAll() }
  }

  var selectedWorktree: WorktreeInfo? {
    guard let selectedPath else { return nil }
    for list in worktrees.values {
      if let match = list.first(where: { $0.path == selectedPath }) { return match }
    }
    return nil
  }

  func clone(forWorktree worktree: WorktreeInfo) -> TrackedClone? {
    clones.first { commonDir in
      worktrees[commonDir.commonDir]?.contains(where: { $0.path == worktree.path }) ?? false
    }
  }

  // MARK: Clones

  private func reloadClones() {
    guard let context else { return }
    let descriptor = FetchDescriptor<TrackedClone>(sortBy: [SortDescriptor(\.displayName)])
    clones = (try? context.fetch(descriptor)) ?? []
  }

  /// Validates the folder is a git repo, then tracks its clone and discovers worktrees.
  @discardableResult
  func addClone(at url: URL) async -> Bool {
    guard let context, await Git.isRepository(url) else { return false }
    guard let common = await Git.commonDir(url) else { return false }

    if clones.contains(where: { $0.commonDir == common }) {
      // Already tracked — just refresh it.
      await refreshClone(commonDir: common, rootURL: url)
      return true
    }

    let remote = await Git.remoteURL(url)
    // Name the clone from its main worktree's folder, not the picked subfolder.
    let worktreeList = await Git.worktrees(in: url)
    let mainPath = worktreeList.first(where: { !$0.isBare })?.path ?? url.path
    let displayName = URL(fileURLWithPath: mainPath).lastPathComponent

    let clone = TrackedClone(commonDir: common, displayName: displayName,
                             rootPath: mainPath, remoteURL: remote)
    context.insert(clone)
    try? context.save()
    reloadClones()

    worktrees[common] = worktreeList.filter { !$0.isBare }
    await loadStatuses(for: common)
    return true
  }

  func removeClone(_ clone: TrackedClone) {
    guard let context else { return }
    worktrees[clone.commonDir] = nil
    if let selectedPath, worktrees.values.flatMap({ $0 }).first(where: { $0.path == selectedPath }) == nil {
      self.selectedPath = nil
    }
    context.delete(clone)
    try? context.save()
    reloadClones()
  }

  // MARK: Discovery & status

  func refreshAll() async {
    refreshing = true
    defer { refreshing = false }
    reloadClones()
    for clone in clones {
      await refreshClone(commonDir: clone.commonDir, rootURL: clone.rootURL)
    }
  }

  func refreshClone(commonDir: String, rootURL: URL) async {
    let list = await Git.worktrees(in: rootURL).filter { !$0.isBare }
    worktrees[commonDir] = list
    await loadStatuses(for: commonDir)
  }

  private func loadStatuses(for commonDir: String) async {
    guard let list = worktrees[commonDir] else { return }
    for worktree in list {
      let base = baseRef(for: worktree)
      statuses[worktree.path] = await Git.status(in: worktree.url, base: base)
      lastFetch[worktree.path] = await Git.lastFetch(in: worktree.url)
    }
  }

  func reloadStatus(for worktree: WorktreeInfo) async {
    statuses[worktree.path] = await Git.status(in: worktree.url, base: baseRef(for: worktree))
    lastFetch[worktree.path] = await Git.lastFetch(in: worktree.url)
  }

  func fetch(_ worktree: WorktreeInfo) async {
    _ = await Git.fetch(in: worktree.url)
    await reloadStatus(for: worktree)
  }

  /// Base ref for ahead/behind: the branch's `PRJ_DEP` from shared config, as `origin/<base>`.
  private func baseRef(for worktree: WorktreeInfo) -> String? {
    guard let branch = worktree.branch else { return nil }
    let config = BranchConfig.load(worktree: worktree.url, branch: branch)
    guard let base = config.prjDep, !base.isEmpty, base != "na" else { return nil }
    return base.hasPrefix("origin/") ? base : "origin/\(base)"
  }
}
