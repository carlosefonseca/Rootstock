import AppKit

/// User preferences that aren't Azure-specific: the in-app terminal font.
enum AppSettings {
  static let terminalFontNameKey = "terminal.fontName"
  static let terminalFontSizeKey = "terminal.fontSize"

  static var terminalFontName: String {
    UserDefaults.standard.string(forKey: terminalFontNameKey) ?? "Monaco"
  }

  static var terminalFontSize: Double {
    let value = UserDefaults.standard.double(forKey: terminalFontSizeKey)
    return value == 0 ? 12 : value
  }

  static func terminalFont() -> NSFont {
    NSFont(name: terminalFontName, size: terminalFontSize)
      ?? .monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
  }

  /// Backs the Cmd+/Cmd- "zoom" shortcut when a terminal tab is focused —
  /// same underlying preference (and live-restyle notification) the Settings
  /// stepper uses, just nudged by a step instead of set to an exact value.
  static func adjustTerminalFontSize(by delta: Double) {
    let clamped = min(24, max(8, terminalFontSize + delta))
    UserDefaults.standard.set(clamped, forKey: terminalFontSizeKey)
    NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
  }

  static func resetTerminalFontSize() {
    UserDefaults.standard.set(12.0, forKey: terminalFontSizeKey)
    NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
  }

  // MARK: Web zoom

  /// Page zoom per hostname, the way Safari does it: zooming a DevOps work item
  /// once applies to every DevOps tab, in every worktree, on every launch —
  /// rather than making it a per-tab setting the user re-does constantly for
  /// the handful of sites this app actually opens.
  private static let webZoomKey = "web.zoomByHost"

  static func webZoom(forHost host: String) -> Double? {
    guard let map = UserDefaults.standard.dictionary(forKey: webZoomKey) as? [String: Double] else { return nil }
    return map[host]
  }

  static func setWebZoom(_ zoom: Double, forHost host: String) {
    var map = (UserDefaults.standard.dictionary(forKey: webZoomKey) as? [String: Double]) ?? [:]
    // 1.0 is the default — drop the entry instead of persisting a no-op.
    if abs(zoom - 1.0) < 0.001 { map[host] = nil } else { map[host] = zoom }
    UserDefaults.standard.set(map, forKey: webZoomKey)
    NotificationCenter.default.post(name: .webZoomChanged, object: nil, userInfo: ["host": host])
  }
}

extension Notification.Name {
  /// Posted when the terminal font preference changes so live sessions restyle.
  static let terminalFontChanged = Notification.Name("rootstock.terminalFontChanged")
  /// Posted when a hostname's page zoom changes so other tabs on the same host
  /// match it immediately rather than only on their next navigation.
  static let webZoomChanged = Notification.Name("rootstock.webZoomChanged")
}
