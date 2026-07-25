import SwiftUI

struct WorktreeDetailView: View {
  var worktree: WorktreeInfo
  @AppStorage("detail.showInspector") private var showInspector = true

  var body: some View {
    MainTabBarView(worktree: worktree)
      .inspector(isPresented: $showInspector) {
        WorktreeInspector(worktree: worktree)
          .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
      }
      .navigationTitle(worktree.folderName)
      .navigationSubtitle(worktree.displayBranch)
      .toolbar {
        ToolbarItem {
          Button("Inspector", systemImage: "sidebar.trailing") {
            withAnimation(.snappy) { showInspector.toggle() }
          }
        }
      }
      .background {
        // Hidden buttons, not app-wide `.commands`, so these act on this
        // worktree's own window/detail pane rather than whichever window last
        // had focus — same scoping trick `MainTabBarView` uses for its tab
        // shortcuts.
        Group {
          Button("", action: { AppOpener.revealInFinder(worktree.url) })
            .keyboardShortcut("r", modifiers: [.command, .shift])
          Button("", action: { AppOpener.openInVSCode(worktree.url) })
            .keyboardShortcut("c", modifiers: [.command, .shift])
          Button("", action: { AppOpener.openInFork(worktree.url) })
            .keyboardShortcut("k", modifiers: [.command, .shift])
          Button("", action: { withAnimation(.snappy) { showInspector.toggle() } })
            .keyboardShortcut("i", modifiers: .command)
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
      }
  }
}
