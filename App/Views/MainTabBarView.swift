import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The main area for a worktree: a tab bar (terminal, work item, Figma, and any
/// tabs the user opens) above whichever tab is selected. Tabs are per-worktree
/// and persist across worktree switches — see `WorktreeTabsStore`.
struct MainTabBarView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(WorktreeTabsStore.self) private var tabsStore
  @Environment(WorktreeLinksStore.self) private var linksStore
  var worktree: WorktreeInfo

  private var tabs: [MainTab] { tabsStore.tabs(for: worktree) }
  private var selectedID: MainTab.ID? { tabsStore.selectedTabID(for: worktree) }
  private var selectedTab: MainTab? { tabs.first { $0.id == selectedID } }

  /// The tab currently being dragged for reordering — tracked so the drop
  /// delegate can tell which chip is moving as it hovers over neighbors.
  @State private var draggedTabID: MainTab.ID?

  /// The clone's local-only terminal init command — typed into every new
  /// terminal tab's shell right after it starts.
  private var terminalInitCommand: String? {
    workspace.clone(forWorktree: worktree)?.terminalInitCommand
  }

  /// Read fresh each time the menu opens, since the shared config can change
  /// (via the config editor) without the tab bar reloading.
  private var quickLinks: [QuickLink] {
    QuickLinks.resolve(for: worktree, linksStore: linksStore)
  }

  /// A URL sitting on the clipboard, for the "+" menu's Paste and Go.
  ///
  /// Only ever called from the button's *action*, never to decide whether to
  /// show it: SwiftUI builds menu content from the last body evaluation, and
  /// the pasteboard isn't observable, so gating visibility on this showed a
  /// stale item — and worse, could hide it when a URL really had been copied.
  private var pasteboardURL: String? {
    guard let raw = NSPasteboard.general.string(forType: .string)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
      raw.contains("://") || raw.hasPrefix("www."),
      WebTabSession.normalizedURL(raw) != nil else { return nil }
    return raw
  }

  var body: some View {
    VStack(spacing: 0) {
      tabBar
      Divider()
      content
    }
    .task(id: worktree.path) {
      tabsStore.ensureDefaultTabs(for: worktree, initialCommand: terminalInitCommand)
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
        Button("", action: {
          let tab = tabsStore.addTerminalTab(for: worktree, initialCommand: terminalInitCommand)
          tabsStore.select(tab.id, for: worktree)
        })
        .keyboardShortcut("t", modifiers: .command)
        Button("", action: {
          let tab = tabsStore.addWebTab(for: worktree)
          tabsStore.select(tab.id, for: worktree)
        })
        .keyboardShortcut("t", modifiers: [.command, .shift])
        // Without this, Cmd+W falls through to the window's default "Close"
        // command and closes the whole window instead of just the tab.
        Button("", action: {
          if let selectedID { tabsStore.close(selectedID, for: worktree) }
        })
        .keyboardShortcut("w", modifiers: .command)
      }
      .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
      // Cmd+1...Cmd+9 jump straight to a tab by position — e.g. the work item
      // or Figma tab, wherever it landed in this worktree's tab order — rather
      // than only being able to cycle one at a time with Ctrl+Tab.
      Group {
        ForEach(1...9, id: \.self) { number in
          Button("", action: { selectTab(at: number - 1) })
            .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
        }
      }
      .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
      // Cmd+/Cmd- "zoom", scoped to whichever tab is focused: the terminal's
      // font size (a shared preference, same one Settings' stepper drives) for
      // a terminal tab, or that page's own WKWebView zoom for a web tab — Cmd+=
      // bound too since "+" needs Shift on most keyboards but people reach for
      // either.
      Group {
        Button("", action: zoomIn).keyboardShortcut("+", modifiers: .command)
        Button("", action: zoomIn).keyboardShortcut("=", modifiers: .command)
        Button("", action: zoomOut).keyboardShortcut("-", modifiers: .command)
        Button("", action: zoomReset).keyboardShortcut("0", modifiers: .command)
      }
      .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
      // Cmd+R reloads the page, as in any browser. Bound only while a web tab
      // is selected: a view's shortcut beats the main menu's, so binding it
      // unconditionally would shadow the app-wide "Refresh All" everywhere
      // else.
      if let session = selectedTab?.webSession {
        Button("", action: { session.reload() })
          .keyboardShortcut("r", modifiers: .command)
          .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
      }
    }
  }

  private func selectTab(at index: Int) {
    guard tabs.indices.contains(index) else { return }
    tabsStore.select(tabs[index].id, for: worktree)
  }

  /// Right-click menu on a tab chip. Web tabs get the link actions; the
  /// close actions apply to any tab.
  @ViewBuilder private func tabContextMenu(_ tab: MainTab) -> some View {
    if let urlString = tab.webSession?.currentURLString, urlString != "about:blank" {
      Button("Open in Browser", systemImage: "safari") { AppOpener.open(urlString) }
      Button("Copy Link", systemImage: "link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
      }
      Button("Duplicate Tab", systemImage: "plus.square.on.square") {
        let new = tabsStore.addWebTab(for: worktree, urlString: urlString,
                                      title: tab.title, systemImage: tab.systemImage)
        tabsStore.select(new.id, for: worktree)
      }
      // Zoom is stored per hostname, so this resets every tab on this host.
      if let session = tab.webSession, abs(session.pageZoom - 1.0) > 0.001 {
        Button("Reset Zoom (\(Int((session.pageZoom * 100).rounded()))%)", systemImage: "arrow.counterclockwise") {
          session.zoomReset()
        }
      }
      Divider()
    }
    Button("Close Tab", systemImage: "xmark") { tabsStore.close(tab.id, for: worktree) }
    Button("Close Other Tabs", systemImage: "xmark.square") {
      for other in tabs where other.id != tab.id {
        tabsStore.close(other.id, for: worktree)
      }
    }
    .disabled(tabs.count < 2)
  }

  private func zoomIn() {
    switch selectedTab?.kind {
    case .terminal: AppSettings.adjustTerminalFontSize(by: 1)
    case .web: selectedTab?.webSession?.zoomIn()
    case nil: break
    }
  }

  private func zoomOut() {
    switch selectedTab?.kind {
    case .terminal: AppSettings.adjustTerminalFontSize(by: -1)
    case .web: selectedTab?.webSession?.zoomOut()
    case nil: break
    }
  }

  private func zoomReset() {
    switch selectedTab?.kind {
    case .terminal: AppSettings.resetTerminalFontSize()
    case .web: selectedTab?.webSession?.zoomReset()
    case nil: break
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
              .contextMenu { tabContextMenu(tab) }
              .onDrag {
                draggedTabID = tab.id
                return NSItemProvider(object: tab.id.uuidString as NSString)
              }
              .onDrop(of: [.text], delegate: TabDropDelegate(
                target: tab, tabs: tabs, draggedTabID: $draggedTabID,
                move: { id, targetID in tabsStore.moveTab(id, before: targetID, for: worktree) }))
          }
        }
      }
      Menu {
        Button("New Terminal Tab", systemImage: "terminal.fill") {
          let tab = tabsStore.addTerminalTab(for: worktree, initialCommand: terminalInitCommand)
          tabsStore.select(tab.id, for: worktree)
        }
        Button("New Web Tab", systemImage: "globe") {
          let tab = tabsStore.addWebTab(for: worktree)
          tabsStore.select(tab.id, for: worktree)
        }
        Button("Paste and Go", systemImage: "doc.on.clipboard") {
          guard let pasted = pasteboardURL else { return }
          let tab = tabsStore.addWebTab(for: worktree, urlString: pasted)
          tabsStore.select(tab.id, for: worktree)
        }

        let links = quickLinks
        if !links.isEmpty {
          Divider()
          ForEach(links) { link in
            Button(link.title, systemImage: link.systemImage) {
              QuickLinks.open(link, worktree: worktree, tabsStore: tabsStore)
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
    HStack(spacing: 6) {
      icon
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
    .padding(.vertical, 8)
    .frame(maxWidth: 160, alignment: .leading)
    .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
    .contentShape(.rect)
    .onTapGesture { select() }
    .onMiddleClick { close() }
    .onHover { hovering = $0 }
    .help(tab.displayTitle)
  }

  @ViewBuilder private var icon: some View {
    if let favicon = tab.webSession?.favicon {
      Image(nsImage: favicon).resizable().frame(width: 14, height: 14)
    } else {
      Image(systemName: tab.systemImage).font(.caption2).frame(width: 14, height: 14)
    }
  }
}

/// Reorders tabs live as a dragged chip hovers over its neighbors, rather
/// than only on drop — the behavior every browser's tab bar has trained
/// people to expect.
private struct TabDropDelegate: DropDelegate {
  var target: MainTab
  var tabs: [MainTab]
  @Binding var draggedTabID: MainTab.ID?
  var move: (_ id: MainTab.ID, _ before: MainTab.ID) -> Void

  func dropEntered(info: DropInfo) {
    guard let draggedTabID, draggedTabID != target.id,
          tabs.contains(where: { $0.id == draggedTabID }) else { return }
    move(draggedTabID, target.id)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedTabID = nil
    return true
  }
}
