import Foundation

/// User-level Azure DevOps preferences kept in `UserDefaults` (not repo config):
/// manually-added orgs, and a default work-item org/project used when a repo's
/// `.dcdp/config.toml` doesn't specify one.
enum AzureSettingsStore {
  private static let manualOrgsKey = "azure.manualOrgs"
  private static let defaultWorkItemOrgKey = "azure.defaultWorkItemOrg"
  private static let defaultWorkItemProjectKey = "azure.defaultWorkItemProject"

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
    return (value?.isEmpty ?? true) ? nil : value
  }

  static var defaultWorkItemProject: String? {
    let value = UserDefaults.standard.string(forKey: defaultWorkItemProjectKey)
    return (value?.isEmpty ?? true) ? nil : value
  }
}
