import Foundation

/// Resolves the work-item org/project for a clone and builds its web URL — shared
/// by `AzureSection` (the inspector card) and `WorktreeTabsStore` (default tabs),
/// which both need the same org-fallback and URL-shape logic.
enum WorkItemLink {
  /// `.dcdp/config.toml` on the clone's main worktree, falling back to the
  /// user's Settings defaults.
  static func resolveOrgProject(clone: TrackedClone?) -> (org: String?, project: String?) {
    let dcdp = clone.map { DcdpConfig.load(worktree: $0.rootURL) } ?? nil
    let org = dcdp?.workItemOrg ?? AzureSettingsStore.defaultWorkItemOrg
    let project = dcdp?.workItemProject ?? AzureSettingsStore.defaultWorkItemProject
    return (org, project)
  }

  /// The org-only form (`/{org}/_workitems/edit/{id}`) 404s on Azure DevOps —
  /// it needs the project segment to resolve.
  static func url(org: String, project: String?, id: String) -> String {
    guard let project, !project.isEmpty else {
      return "https://dev.azure.com/\(org)/_workitems/edit/\(id)"
    }
    let encodedProject = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
    return "https://dev.azure.com/\(org)/\(encodedProject)/_workitems/edit/\(id)"
  }
}
