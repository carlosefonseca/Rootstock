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
}

extension Notification.Name {
  /// Posted when the terminal font preference changes so live sessions restyle.
  static let terminalFontChanged = Notification.Name("rootstock.terminalFontChanged")
}
