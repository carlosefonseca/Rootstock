import Foundation

/// User-level Azure DevOps preferences kept in `UserDefaults` (not repo
/// config): known orgs (auto-registered as work item URLs are used, or added
/// manually) and each one's PAT/auth mode.
enum AzureSettingsStore {
  private static let manualOrgsKey = "azure.manualOrgs"

  /// How Rootstock authenticates to an org.
  enum AuthMode: String, CaseIterable, Identifiable {
    case auto   // PAT if stored, otherwise az
    case az     // az session only — never touches the keychain
    case pat    // stored PAT only

    var id: String { rawValue }
    var label: String {
      switch self {
      case .auto: return "Automatic"
      case .az: return "az (AAD)"
      case .pat: return "PAT"
      }
    }
  }

  static func authMode(org: String) -> AuthMode {
    guard let raw = UserDefaults.standard.string(forKey: "azure.authMode.\(org)"),
          let mode = AuthMode(rawValue: raw) else { return .auto }
    return mode
  }

  static func setAuthMode(_ mode: AuthMode, org: String) {
    UserDefaults.standard.set(mode.rawValue, forKey: "azure.authMode.\(org)")
  }

  static var manualOrgs: [String] {
    get { UserDefaults.standard.stringArray(forKey: manualOrgsKey) ?? [] }
    set { UserDefaults.standard.set(newValue, forKey: manualOrgsKey) }
  }

  static func addManualOrg(_ org: String) {
    let trimmed = org.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var orgs = manualOrgs
    guard !orgs.contains(trimmed) else { return }
    orgs.append(trimmed)
    manualOrgs = orgs
  }

  static func removeManualOrg(_ org: String) {
    manualOrgs = manualOrgs.filter { $0 != org }
  }
}
