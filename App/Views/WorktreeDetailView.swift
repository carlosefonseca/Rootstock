import SwiftUI

struct WorktreeDetailView: View {
  var worktree: WorktreeInfo
  @AppStorage("detail.showInspector") private var showInspector = true

  var body: some View {
    WorktreeTerminalPane(worktree: worktree)
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
  }
}
