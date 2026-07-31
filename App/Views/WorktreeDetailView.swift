import SwiftUI

struct WorktreeDetailView: View {
  @Environment(WorkspaceModel.self) private var workspace
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
        // Only while the inspector is hidden — otherwise it's just repeating
        // the Status card sitting a few inches to the right.
        if !showInspector {
          ToolbarItem {
            ToolbarStatusSummary(status: workspace.statuses[worktree.path])
          }
        }
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

/// The Status card's headline facts, condensed to a row of pills for the
/// toolbar: what's uncommitted, and how far the branch has drifted. Shown only
/// when the inspector is collapsed, so that information doesn't disappear
/// entirely just because the pane is hidden.
private struct ToolbarStatusSummary: View {
  var status: WorktreeStatus?

  var body: some View {
    if let status {
      HStack(spacing: 6) {
        StatusDot(dot: status.dot)
        if status.conflicted > 0 {
          pill("\(status.conflicted)", icon: "exclamationmark.triangle.fill", tint: .red)
        } else if status.changedCount > 0 {
          pill("\(status.changedCount)", icon: "pencil", tint: .orange)
        }
        let ahead = status.hasUpstream ? status.remoteAhead : status.baseAhead
        let behind = status.hasUpstream ? status.remoteBehind : status.baseBehind
        if ahead > 0 { pill("\(ahead)", icon: "arrow.up", tint: .blue) }
        if behind > 0 { pill("\(behind)", icon: "arrow.down", tint: .purple) }
      }
      .help(helpText(status))
    }
  }

  private func pill(_ text: String, icon: String, tint: Color) -> some View {
    Label(text, systemImage: icon)
      // Explicit, because a toolbar otherwise renders labels icon-only and
      // the counts — the whole point of the summary — disappear.
      .labelStyle(.titleAndIcon)
      .font(.caption.weight(.medium))
      .imageScale(.small)
      .foregroundStyle(tint)
  }

  private func helpText(_ status: WorktreeStatus) -> String {
    var parts: [String] = []
    parts.append(status.changedCount > 0
                 ? "\(status.changedCount) modified file\(status.changedCount == 1 ? "" : "s")"
                 : "Working tree clean")
    if status.conflicted > 0 { parts.append("\(status.conflicted) in conflict") }
    let against = status.hasUpstream ? "remote" : (status.baseName ?? "base")
    let ahead = status.hasUpstream ? status.remoteAhead : status.baseAhead
    let behind = status.hasUpstream ? status.remoteBehind : status.baseBehind
    if ahead > 0 || behind > 0 {
      parts.append("ahead \(ahead) / behind \(behind) of \(against)")
    }
    return parts.joined(separator: " · ")
  }
}
