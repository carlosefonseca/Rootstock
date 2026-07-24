import SwiftUI

/// The main area for a worktree: a tab bar (terminal, work item, Figma, and any
/// tabs the user opens) above whichever tab is selected. Tabs are per-worktree
/// and persist across worktree switches — see `WorktreeTabsStore`.
struct MainTabBarView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(WorktreeTabsStore.self) private var tabsStore
  var worktree: WorktreeInfo

  private var tabs: [MainTab] { tabsStore.tabs(for: worktree) }
  private var selectedID: MainTab.ID? { tabsStore.selectedTabID(for: worktree) }
  private var selectedTab: MainTab? { tabs.first { $0.id == selectedID } }

  var body: some View {
    VStack(spacing: 0) {
      tabBar
      Divider()
      content
    }
    .task(id: worktree.path) {
      tabsStore.ensureDefaultTabs(for: worktree, clone: workspace.clone(forWorktree: worktree))
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

  @ViewBuilder private var content: some View {
    if let tab = selectedTab {
      switch tab.kind {
      case .terminal:
        if let session = tab.terminalSession {
          TerminalTabPane(session: session)
        }
      case .web:
        if let session = tab.webSession {
          WebTabPane(session: session)
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
