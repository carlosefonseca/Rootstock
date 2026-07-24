import SwiftUI

/// The main area for a worktree: a tab bar (terminal, work item, Figma, and any
/// tabs the user opens) above whichever tab is selected. Tabs are per-worktree
/// and persist across worktree switches — see `WorktreeTabsStore`.
struct MainTabBarView: View {
  @Environment(WorktreeTabsStore.self) private var tabsStore
  @Environment(WorktreeLinksStore.self) private var linksStore
  var worktree: WorktreeInfo

  private var tabs: [MainTab] { tabsStore.tabs(for: worktree) }
  private var selectedID: MainTab.ID? { tabsStore.selectedTabID(for: worktree) }
  private var selectedTab: MainTab? { tabs.first { $0.id == selectedID } }

  /// The branch's shared config — read fresh each time the menu opens, since
  /// it can change (via the config editor) without the tab bar reloading.
  private var branchConfig: BranchConfig? {
    guard let branch = worktree.branch else { return nil }
    return BranchConfig.load(worktree: worktree.url, branch: branch)
  }

  /// Work items are self-describing URLs, so listing them for the quick-link
  /// menu needs no org/project resolution — just parsing what's configured.
  private var workItemURLs: [WorkItemURL] {
    (branchConfig?.workItemURLs ?? []).compactMap { WorkItemURL.parse($0) }
  }

  private var hasAnyQuickLink: Bool {
    linksStore.pullRequestURL(for: worktree) != nil || !workItemURLs.isEmpty ||
    !(branchConfig?.figmaURL ?? "").isEmpty || !(branchConfig?.slackChannelURL ?? "").isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      tabBar
      Divider()
      content
    }
    .task(id: worktree.path) {
      tabsStore.ensureDefaultTabs(for: worktree)
    }
    .background {
      // Invisible buttons rather than a `.commands` menu item: those are
      // app-wide and would cycle whichever worktree window last had focus,
      // not necessarily this one. A hidden button's shortcut is scoped to
      // this view's window like any other SwiftUI control.
      Group {
        Button("", action: { tabsStore.selectAdjacent(offset: 1, for: worktree) })
          .keyboardShortcut(.tab, modifiers: .control)
        Button("", action: { tabsStore.selectAdjacent(offset: -1, for: worktree) })
          .keyboardShortcut(.tab, modifiers: [.control, .shift])
      }
      .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }
  }

  private var tabBar: some View {
    HStack(spacing: 4) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(tabs) { tab in
            TabChip(tab: tab, isSelected: tab.id == selectedID,
                    select: { tabsStore.select(tab.id, for: worktree) },
                    close: { tabsStore.close(tab.id, for: worktree) })
          }
        }
      }
      Menu {
        Button("New Terminal Tab", systemImage: "terminal") {
          let tab = tabsStore.addTerminalTab(for: worktree)
          tabsStore.select(tab.id, for: worktree)
        }
        Button("New Web Tab", systemImage: "globe") {
          let tab = tabsStore.addWebTab(for: worktree)
          tabsStore.select(tab.id, for: worktree)
        }

        if hasAnyQuickLink {
          Divider()
          if let prURL = linksStore.pullRequestURL(for: worktree) {
            Button("Pull Request", systemImage: "arrow.triangle.pull") {
              WebLinkOpener.open(prURL, title: "Pull Request", systemImage: "arrow.triangle.pull",
                                 worktree: worktree, tabsStore: tabsStore)
            }
          }
          ForEach(workItemURLs, id: \.self) { wiURL in
            Button("Work Item #\(wiURL.id)", systemImage: "checklist") {
              WebLinkOpener.open(wiURL.canonical, title: "Work Item #\(wiURL.id)", systemImage: "checklist",
                                 worktree: worktree, tabsStore: tabsStore)
            }
          }
          if let figma = branchConfig?.figmaURL, !figma.isEmpty {
            Button("Figma", systemImage: "paintbrush.pointed") {
              WebLinkOpener.open(figma, title: "Figma", systemImage: "paintbrush.pointed",
                                 worktree: worktree, tabsStore: tabsStore)
            }
          }
          if let slack = branchConfig?.slackChannelURL, !slack.isEmpty {
            Button("Slack", systemImage: "bubble.left.and.bubble.right") {
              AppOpener.openSlack(slack)
            }
          }
        }
      } label: {
        Image(systemName: "plus")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 26)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
  }

  // Each tab's pane is forced to a fresh identity keyed by the tab itself —
  // otherwise SwiftUI sees the same view type at the same tree position across
  // a tab switch and *updates* it instead of remounting, which for a
  // NSViewRepresentable wrapping a pre-existing, per-session NSView means the
  // old tab's WKWebView/terminal view just stays on screen forever.
  @ViewBuilder private var content: some View {
    if let tab = selectedTab {
      switch tab.kind {
      case .terminal:
        if let session = tab.terminalSession {
          TerminalTabPane(session: session).id(tab.id)
        }
      case .web:
        if let session = tab.webSession {
          WebTabPane(session: session).id(tab.id)
        }
      }
    } else {
      ContentUnavailableView("No Tabs", systemImage: "square.on.square")
    }
  }
}

private struct TabChip: View {
  var tab: MainTab
  var isSelected: Bool
  var select: () -> Void
  var close: () -> Void

  @State private var hovering = false

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: tab.systemImage).font(.caption2)
      Text(tab.displayTitle).font(.caption).lineLimit(1)
      if hovering || isSelected {
        Button(action: close) {
          Image(systemName: "xmark.circle.fill").font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .frame(maxWidth: 160, alignment: .leading)
    .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
    .contentShape(.rect)
    .onTapGesture { select() }
    .onHover { hovering = $0 }
    .help(tab.displayTitle)
  }
}
