import Foundation

/// User-level Azure DevOps preferences kept in `UserDefaults` (not repo config):
/// manually-added orgs, and a default work-item org/project used when a repo's
/// `.dcdp/config.toml` doesn't specify one.
enum AzureSettingsStore {
  private static let manualOrgsKey = "azure.manualOrgs"
  private static let defaultWorkItemOrgKey = "azure.defaultWorkItemOrg"
  private static let defaultWorkItemProjectKey = "azure.defaultWorkItemProject"

  /// The team's actual work-item org/project — shown pre-filled in Settings and
  /// used whenever the field is left empty, rather than a placeholder nobody reads.
  static let defaultWorkItemOrgFallback = "CASDevOps"
  static let defaultWorkItemProjectFallback = "CA Entrega"

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

  static var defaultWorkItemOrg: String? {
    let value = UserDefaults.standard.string(forKey: defaultWorkItemOrgKey)
    return (value?.isEmpty ?? true) ? defaultWorkItemOrgFallback : value
  }

  static var defaultWorkItemProject: String? {
    let value = UserDefaults.standard.string(forKey: defaultWorkItemProjectKey)
    return (value?.isEmpty ?? true) ? defaultWorkItemProjectFallback : value
  }
}
