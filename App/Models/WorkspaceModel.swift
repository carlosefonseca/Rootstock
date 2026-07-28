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
    didSet {
      UserDefaults.standard.set(selectedPath, forKey: Self.selectedPathKey)
      if let selectedPath { recordRecent(selectedPath) }
    }
  }
  private static let selectedPathKey = "workspace.selectedPath"

  /// Most-recently-selected worktree paths, newest first, pooled across every
  /// clone rather than grouped by repo — lets the sidebar surface the 2-3
  /// worktrees actually in use out of however many are tracked.
  private(set) var recentPaths: [String] {
    didSet { UserDefaults.standard.set(recentPaths, forKey: Self.recentPathsKey) }
  }
  private static let recentPathsKey = "workspace.recentPaths"
  private static let maxRecents = 5

  @ObservationIgnored private var context: ModelContext?

  init() {
    recentPaths = UserDefaults.standard.stringArray(forKey: Self.recentPathsKey) ?? []
    selectedPath = UserDefaults.standard.string(forKey: Self.selectedPathKey)
  }

  private func recordRecent(_ path: String) {
    var paths = recentPaths
    paths.removeAll { $0 == path }
    paths.insert(path, at: 0)
    if paths.count > Self.maxRecents { paths.removeLast(paths.count - Self.maxRecents) }
    recentPaths = paths
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

  /// Every worktree across every clone, in the same order the sidebar lists
  /// them (clones sorted by display name, worktrees within a clone in
  /// discovery order) — what worktree-switching shortcuts cycle through.
  var orderedWorktrees: [WorktreeInfo] {
    clones.flatMap { worktrees[$0.commonDir] ?? [] }
  }

  /// Selects the next/previous worktree in `orderedWorktrees`, wrapping
  /// around. Drives the Cmd+Option+Right/Left "switch worktree" shortcuts.
  func selectAdjacentWorktree(offset: Int) {
    let list = orderedWorktrees
    guard !list.isEmpty else { return }
    let currentIndex = selectedPath.flatMap { path in list.firstIndex { $0.path == path } } ?? -1
    let count = list.count
    let newIndex = ((currentIndex + offset) % count + count) % count
    selectedPath = list[newIndex].path
  }

  /// `recentPaths` resolved to their live `WorktreeInfo`, newest first. Paths
  /// whose worktree was since removed (clone untracked, worktree deleted)
  /// are silently dropped rather than shown as stale entries.
  var recentWorktrees: [WorktreeInfo] {
    recentPaths.compactMap { path in
      for list in worktrees.values {
        if let match = list.first(where: { $0.path == path }) { return match }
      }
      return nil
    }
  }

  func clone(forWorktree worktree: WorktreeInfo) -> TrackedClone? {
    clones.first { commonDir in
      worktrees[commonDir.commonDir]?.contains(where: { $0.path == worktree.path }) ?? false
    }
  }

  /// The worktree already checked out to `branch` within `clone`, if any —
  /// lets a branch/PR picker offer to jump to an existing worktree instead of
  /// creating a duplicate one.
  func worktree(in clone: TrackedClone, branch: String) -> WorktreeInfo? {
    worktrees[clone.commonDir]?.first { $0.branch == branch }
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

  func setTerminalInitCommand(_ command: String?, for clone: TrackedClone) {
    clone.terminalInitCommand = command
    try? context?.save()
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
