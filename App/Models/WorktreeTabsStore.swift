import Foundation
import Observation
import WebKit

/// A tab's persisted shape — just enough to recreate it on next launch. Live
/// session state (a running shell, a loaded page) can't survive a restart, so
/// terminal tabs come back as a fresh shell and web tabs reload their last URL.
private struct PersistedTab: Codable {
  var kind: MainTabKind
  var title: String
  var systemImage: String
  var urlString: String?
}

private struct PersistedWorktreeTabs: Codable {
  var tabs: [PersistedTab]
  var selectedIndex: Int?
}

/// App-lifetime owner of each worktree's tab bar. Tabs (and the sessions they
/// hold) persist across worktree switches — matching how terminal sessions used
/// to behave — since this store, not the view, is what's alive for the app's
/// duration. The tab *list* (kind/title/URL) is also persisted to disk so it
/// survives an app restart; the sessions themselves are rebuilt fresh.
@Observable
@MainActor
final class WorktreeTabsStore {
  private(set) var tabsByWorktree: [String: [MainTab]] = [:]
  private(set) var selection: [String: MainTab.ID] = [:]
  /// The clone-level terminal init command for each worktree, refreshed on
  /// every `ensureDefaultTabs`/`addTerminalTab` call so an edit made in
  /// Settings applies to the next terminal opened, not just app relaunch.
  private var initialCommands: [String: String] = [:]

  private static let storageKey = "tabs.persisted"

  func tabs(for worktree: WorktreeInfo) -> [MainTab] {
    tabsByWorktree[worktree.path] ?? []
  }

  func selectedTabID(for worktree: WorktreeInfo) -> MainTab.ID? {
    selection[worktree.path]
  }

  /// Restores the worktree's tabs from a previous session if any were saved;
  /// otherwise builds the starting set: a terminal, plus a work-item tab and a
  /// Figma tab when the branch's shared config already has them set. Only ever
  /// runs once per worktree per launch.
  func ensureDefaultTabs(for worktree: WorktreeInfo, initialCommand: String? = nil) {
    initialCommands[worktree.path] = (initialCommand?.isEmpty == false) ? initialCommand : nil
    guard tabsByWorktree[worktree.path] == nil else { return }

    if let saved = Self.loadPersisted()[worktree.path], !saved.tabs.isEmpty {
      let tabs = saved.tabs.map { restoreTab(from: $0, worktree: worktree) }
      tabsByWorktree[worktree.path] = tabs
      let index = saved.selectedIndex.flatMap { tabs.indices.contains($0) ? $0 : nil } ?? 0
      selection[worktree.path] = tabs[index].id
      return
    }

    var tabs = [makeTerminalTab(for: worktree, title: "Terminal")]

    if let branch = worktree.branch {
      let config = BranchConfig.load(worktree: worktree.url, branch: branch)

      for wiURL in config.workItemURLs.compactMap({ WorkItemURL.parse($0) }) {
        tabs.append(makeWebTab(title: "Work Item #\(wiURL.id)", systemImage: "checklist",
                               urlString: wiURL.canonical, worktree: worktree))
      }
      if let figma = config.figmaURL, !figma.isEmpty {
        tabs.append(makeWebTab(title: "Figma", systemImage: "paintbrush.pointed", urlString: figma, worktree: worktree))
      }
    }

    tabsByWorktree[worktree.path] = tabs
    selection[worktree.path] = tabs.first?.id
    persist()
  }

  func select(_ id: MainTab.ID, for worktree: WorktreeInfo) {
    selection[worktree.path] = id
    persist()
  }

  /// Cycles the selected tab forward/backward, wrapping around — driven by the
  /// Ctrl+Tab / Ctrl+Shift+Tab shortcuts in `MainTabBarView`.
  func selectAdjacent(offset: Int, for worktree: WorktreeInfo) {
    let tabs = tabs(for: worktree)
    guard !tabs.isEmpty else { return }
    let currentIndex = selection[worktree.path].flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
    let count = tabs.count
    let newIndex = ((currentIndex + offset) % count + count) % count
    select(tabs[newIndex].id, for: worktree)
  }

  @discardableResult
  func addTerminalTab(for worktree: WorktreeInfo, initialCommand: String? = nil) -> MainTab {
    initialCommands[worktree.path] = (initialCommand?.isEmpty == false) ? initialCommand : nil
    let tab = makeTerminalTab(for: worktree, title: "Terminal")
    tabsByWorktree[worktree.path, default: []].append(tab)
    selection[worktree.path] = tab.id
    persist()
    return tab
  }

  /// `urlString` defaults to a blank tab (the "+" menu's "New Web Tab") but is
  /// also how a right-click "Open in New Tab" on a page's link lands here.
  @discardableResult
  func addWebTab(for worktree: WorktreeInfo, urlString: String = "about:blank",
                 title: String = "New Tab", systemImage: String = "globe") -> MainTab {
    let tab = makeWebTab(title: title, systemImage: systemImage, urlString: urlString, worktree: worktree)
    tabsByWorktree[worktree.path, default: []].append(tab)
    selection[worktree.path] = tab.id
    persist()
    return tab
  }

  /// Opens `urlString` for `worktree` — reusing an existing tab with the same
  /// title (e.g. the default "Work Item" tab, or a tab opened this same way
  /// before) rather than creating a duplicate every time a link is clicked.
  @discardableResult
  func openWebTab(title: String, systemImage: String, urlString: String, for worktree: WorktreeInfo) -> MainTab {
    if let existing = tabsByWorktree[worktree.path]?.first(where: { $0.kind == .web && $0.title == title }) {
      existing.webSession?.load(urlString)
      selection[worktree.path] = existing.id
      persist()
      return existing
    }
    let tab = makeWebTab(title: title, systemImage: systemImage, urlString: urlString, worktree: worktree)
    tabsByWorktree[worktree.path, default: []].append(tab)
    selection[worktree.path] = tab.id
    persist()
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
    persist()
  }

  private func makeTerminalTab(for worktree: WorktreeInfo, title: String) -> MainTab {
    let session = TerminalSession(id: UUID().uuidString, directory: worktree.url, title: title)
    session.start(initialCommand: initialCommands[worktree.path])
    return MainTab(kind: .terminal, title: title, systemImage: "terminal", terminalSession: session)
  }

  private func makeWebTab(title: String, systemImage: String, urlString: String, worktree: WorktreeInfo) -> MainTab {
    let session = WebTabSession(urlString: urlString)
    session.onNavigate = { [weak self] in self?.persist() }
    session.onOpenInNewTab = { [weak self] linkURL in
      self?.addWebTab(for: worktree, urlString: linkURL)
    }
    return MainTab(kind: .web, title: title, systemImage: systemImage, webSession: session)
  }

  private func restoreTab(from saved: PersistedTab, worktree: WorktreeInfo) -> MainTab {
    switch saved.kind {
    case .terminal:
      return makeTerminalTab(for: worktree, title: saved.title)
    case .web:
      return makeWebTab(title: saved.title, systemImage: saved.systemImage,
                        urlString: saved.urlString ?? "about:blank", worktree: worktree)
    }
  }

  // MARK: Web data

  /// Wipes everything WebKit's shared data store holds — cookies, cache,
  /// local/session storage, service workers, IndexedDB — across every web
  /// tab, then reloads whichever ones are currently open. A last-resort reset
  /// for a site session that's gotten stuck in a bad state no amount of
  /// logging out/in fixes (e.g. a stale cookie/cache combination left behind
  /// by a broken auth redirect).
  func clearAllWebData() {
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
      guard let self else { return }
      for tabs in self.tabsByWorktree.values {
        for tab in tabs where tab.kind == .web {
          tab.webSession?.webView.reloadFromOrigin()
        }
      }
    }
  }

  // MARK: Persistence

  private func persist() {
    var snapshot: [String: PersistedWorktreeTabs] = [:]
    for (path, tabs) in tabsByWorktree {
      let persistedTabs = tabs.map {
        PersistedTab(kind: $0.kind, title: $0.title, systemImage: $0.systemImage,
                     urlString: $0.webSession?.currentURLString)
      }
      let index = selection[path].flatMap { id in tabs.firstIndex { $0.id == id } }
      snapshot[path] = PersistedWorktreeTabs(tabs: persistedTabs, selectedIndex: index)
    }
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    UserDefaults.standard.set(data, forKey: Self.storageKey)
  }

  private static func loadPersisted() -> [String: PersistedWorktreeTabs] {
    guard let data = UserDefaults.standard.data(forKey: storageKey),
          let decoded = try? JSONDecoder().decode([String: PersistedWorktreeTabs].self, from: data)
    else { return [:] }
    return decoded
  }
}
