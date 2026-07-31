import SwiftUI

/// One of a worktree's configured destinations — the PR, its work items, Figma,
/// Slack. Resolved from the branch's shared config plus the cached PR lookup.
struct QuickLink: Identifiable, Hashable {
  var id: String { title }
  var title: String
  var systemImage: String
  var urlString: String
  /// Slack opens via its native app rather than an in-app web tab.
  var prefersNativeApp = false
}

enum QuickLinks {
  /// The worktree's links, in the order they're worth reaching for. Reads the
  /// shared config fresh each call, since the config editor can change it
  /// without anything here reloading.
  @MainActor
  static func resolve(for worktree: WorktreeInfo, linksStore: WorktreeLinksStore) -> [QuickLink] {
    var links: [QuickLink] = []
    if let prURL = linksStore.pullRequestURL(for: worktree) {
      links.append(QuickLink(title: "Pull Request", systemImage: "arrow.triangle.pull", urlString: prURL))
    }
    guard let branch = worktree.branch else { return links }
    let config = BranchConfig.load(worktree: worktree.url, branch: branch)

    for wiURL in config.workItemURLs.compactMap({ WorkItemURL.parse($0) }) {
      links.append(QuickLink(title: "Work Item #\(wiURL.id)", systemImage: "checklist",
                             urlString: wiURL.canonical))
    }
    if let figma = config.figmaURL, !figma.isEmpty {
      links.append(QuickLink(title: "Figma", systemImage: "paintbrush.pointed", urlString: figma))
    }
    if let slack = config.slackChannelURL, !slack.isEmpty {
      links.append(QuickLink(title: "Slack", systemImage: "bubble.left.and.bubble.right",
                             urlString: slack, prefersNativeApp: true))
    }
    return links
  }

  /// Opens a link the way its kind wants to be opened — Slack in its app,
  /// everything else in a tab (or the system browser with Cmd/Option held,
  /// per `WebLinkOpener`).
  @MainActor
  static func open(_ link: QuickLink, worktree: WorktreeInfo, tabsStore: WorktreeTabsStore) {
    if link.prefersNativeApp {
      AppOpener.openSlack(link.urlString)
    } else {
      WebLinkOpener.open(link.urlString, title: link.title, systemImage: link.systemImage,
                         worktree: worktree, tabsStore: tabsStore)
    }
  }
}

/// The worktree's quick links as a wrapping row of chips. Lives in the
/// inspector's top card so these destinations are visible at a glance rather
/// than buried behind the tab bar's "+" menu, which reads as "new tab".
/// Purely presentational — the caller resolves the links and decides whether
/// to include the row at all, so an empty row never takes up a slot (and its
/// surrounding stack spacing) in the layout.
struct QuickLinksRow: View {
  @Environment(WorktreeTabsStore.self) private var tabsStore
  var worktree: WorktreeInfo
  var links: [QuickLink]

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(links) { link in
        Button {
          QuickLinks.open(link, worktree: worktree, tabsStore: tabsStore)
        } label: {
          Label(link.title, systemImage: link.systemImage)
            .font(.caption)
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("\(link.title) — hold ⌘ to open in your browser")
      }
    }
  }
}

/// Wraps chips onto as many lines as they need — `HStack` would clip them and
/// the inspector column is narrow enough that two or three links already
/// overflow.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var totalWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
        totalHeight += rowHeight + spacing
        totalWidth = max(totalWidth, rowWidth)
        rowWidth = size.width
        rowHeight = size.height
      } else {
        rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
        rowHeight = max(rowHeight, size.height)
      }
    }
    totalWidth = max(totalWidth, rowWidth)
    totalHeight += rowHeight
    return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
