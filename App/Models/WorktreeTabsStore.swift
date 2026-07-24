import Foundation
import Observation

/// App-lifetime owner of each worktree's tab bar. Tabs (and the sessions they
/// hold) persist across worktree switches — matching how terminal sessions used
/// to behave — since this store, not the view, is what's alive for the app's
/// duration.
@Observable
@MainActor
final class WorktreeTabsStore {
  private(set) var tabsByWorktree: [String: [MainTab]] = [:]
  private(set) var selection: [String: MainTab.ID] = [:]

  func tabs(for worktree: WorktreeInfo) -> [MainTab] {
    tabsByWorktree[worktree.path] ?? []
  }

  func selectedTabID(for worktree: WorktreeInfo) -> MainTab.ID? {
    selection[worktree.path]
  }

  /// Builds the worktree's starting tabs the first time it's opened: a terminal,
  /// plus a work-item tab and a Figma tab when the branch's shared config already
  /// has them set. Only ever runs once per worktree — later edits to the config
  /// don't retroactively add tabs to an already-open worktree.
  func ensureDefaultTabs(for worktree: WorktreeInfo, clone: TrackedClone?) {
    guard tabsByWorktree[worktree.path] == nil else { return }

    var tabs = [makeTerminalTab(for: worktree, title: "Terminal")]

    if let branch = worktree.branch {
      let config = BranchConfig.load(worktree: worktree.url, branch: branch)

      if let workItemID = config.workItemID, !workItemID.isEmpty {
        let (org, project) = WorkItemLink.resolveOrgProject(clone: clone)
        if let org {
          let url = WorkItemLink.url(org: org, project: project, id: workItemID)
          tabs.append(MainTab(kind: .web, title: "Work Item", systemImage: "checklist",
                              webSession: WebTabSession(urlString: url)))
        }
      }
      if let figma = config.figmaURL, !figma.isEmpty {
        tabs.append(MainTab(kind: .web, title: "Figma", systemImage: "paintbrush.pointed",
                            webSession: WebTabSession(urlString: figma)))
      }
    }

    tabsByWorktree[worktree.path] = tabs
    selection[worktree.path] = tabs.first?.id
  }

  func select(_ id: MainTab.ID, for worktree: WorktreeInfo) {
    selection[worktree.path] = id
  }

  @discardableResult
  func addTerminalTab(for worktree: WorktreeInfo) -> MainTab {
    let tab = makeTerminalTab(for: worktree, title: "Terminal")
    tabsByWorktree[worktree.path, default: []].append(tab)
    selection[worktree.path] = tab.id
    return tab
  }

  @discardableResult
  func addWebTab(for worktree: WorktreeInfo) -> MainTab {
    let tab = MainTab(kind: .web, title: "New Tab", systemImage: "globe",
                      webSession: WebTabSession(urlString: "about:blank"))
    tabsByWorktree[worktree.path, default: []].append(tab)
    selection[worktree.path] = tab.id
    return tab
  }

  /// Closes a tab, terminating its session. Never leaves a worktree with zero
  /// tabs — a fresh terminal tab replaces the last one closed.
  func close(_ id: MainTab.ID, for worktree: WorktreeInfo) {
    guard var tabs = tabsByWorktree[worktree.path],
          let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let closed = tabs.remove(at: index)
    closed.close()

    let wasSelected = selection[worktree.path] == id
    if tabs.isEmpty {
      tabs = [makeTerminalTab(for: worktree, title: "Terminal")]
    }
    tabsByWorktree[worktree.path] = tabs
    if wasSelected {
      let newIndex = min(index, tabs.count - 1)
      selection[worktree.path] = tabs[newIndex].id
    }
  }

  private func makeTerminalTab(for worktree: WorktreeInfo, title: String) -> MainTab {
    let session = TerminalSession(id: UUID().uuidString, directory: worktree.url, title: title)
    session.start()
    return MainTab(kind: .terminal, title: title, systemImage: "terminal", terminalSession: session)
  }
}
