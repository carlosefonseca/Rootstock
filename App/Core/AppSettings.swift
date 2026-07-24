import AppKit

/// User preferences that aren't Azure-specific: the external terminal app and the
/// in-app terminal font.
enum AppSettings {
  static let terminalAppPathKey = "terminal.appPath"
  static let terminalFontNameKey = "terminal.fontName"
  static let terminalFontSizeKey = "terminal.fontSize"

  static let defaultTerminalAppPath = "/System/Applications/Utilities/Terminal.app"

  static var terminalAppURL: URL {
    let path = UserDefaults.standard.string(forKey: terminalAppPathKey) ?? defaultTerminalAppPath
    return URL(fileURLWithPath: path)
  }

  static var terminalFontName: String {
    UserDefaults.standard.string(forKey: terminalFontNameKey) ?? "Menlo"
  }

  static var terminalFontSize: Double {
    let value = UserDefaults.standard.double(forKey: terminalFontSizeKey)
    return value == 0 ? 12 : value
  }

  static func terminalFont() -> NSFont {
    NSFont(name: terminalFontName, size: terminalFontSize)
      ?? .monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
  }
}

extension Notification.Name {
  /// Posted when the terminal font preference changes so live sessions restyle.
  static let terminalFontChanged = Notification.Name("rootstock.terminalFontChanged")
}
