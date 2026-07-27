import Foundation

/// A parsed Azure DevOps pull request URL. Org, project, repo, and id all come
/// straight from the URL itself, the same self-describing approach as
/// `WorkItemURL` — lets a branch reference PRs beyond the one auto-detected by
/// source branch name (e.g. when the work was split across several PRs).
struct PullRequestURL: Equatable, Hashable {
  var org: String
  var project: String
  var repo: String
  var id: Int

  var canonical: String { AzureRemote(org: org, project: project, repo: repo).pullRequestURL(id: id) }

  /// Parses a pasted Azure DevOps pull request URL — the current
  /// `dev.azure.com` form or the legacy `{org}.visualstudio.com` form.
  static func parse(_ input: String) -> PullRequestURL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host else { return nil }

    var segments = url.pathComponents.filter { $0 != "/" }.map { $0.removingPercentEncoding ?? $0 }
    if segments.first == "DefaultCollection" { segments.removeFirst() }

    let org: String
    if host == "dev.azure.com" {
      guard !segments.isEmpty else { return nil }
      org = segments.removeFirst()
    } else if host.hasSuffix(".visualstudio.com") {
      org = String(host.split(separator: ".").first ?? "")
    } else {
      return nil
    }

    guard let gitIdx = segments.firstIndex(of: "_git"), gitIdx > 0, gitIdx + 1 < segments.count else { return nil }
    let project = segments[gitIdx - 1]
    let repo = segments[gitIdx + 1]
    guard let prIdx = segments.firstIndex(of: "pullrequest"), prIdx + 1 < segments.count,
          let id = Int(segments[prIdx + 1])
    else { return nil }
    return PullRequestURL(org: org, project: project, repo: repo, id: id)
  }
}
