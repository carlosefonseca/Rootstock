import Foundation
import Observation

enum MainTabKind: Equatable {
  case terminal
  case web
}

/// One tab in a worktree's main area — either a terminal session or a web page.
/// Owns its session directly so the tab's lifetime *is* the session's lifetime;
/// no separate app-wide session registry to keep in sync.
@Observable
@MainActor
final class MainTab: Identifiable {
  let id = UUID()
  let kind: MainTabKind
  var title: String
  let systemImage: String
  var closable: Bool

  private(set) var terminalSession: TerminalSession?
  private(set) var webSession: WebTabSession?

  init(kind: MainTabKind, title: String, systemImage: String,
       terminalSession: TerminalSession? = nil, webSession: WebTabSession? = nil,
       closable: Bool = true) {
    self.kind = kind
    self.title = title
    self.systemImage = systemImage
    self.terminalSession = terminalSession
    self.webSession = webSession
    self.closable = closable
  }

  /// What the tab chip should actually display — the live page/shell title once
  /// known, falling back to the tab's given title.
  var displayTitle: String {
    switch kind {
    case .terminal: return terminalSession?.title ?? title
    case .web: return webSession?.title ?? title
    }
  }

  func close() {
    terminalSession?.terminate()
  }
}
