import Foundation

/// The Azure DevOps coordinates parsed from a clone's `origin` remote. Both URL
/// shapes the plan calls out are handled, plus the SSH form.
struct AzureRemote: Equatable {
  var org: String
  var project: String
  var repo: String

  /// Web URL for a pull request.
  func pullRequestURL(id: Int) -> String {
    "https://dev.azure.com/\(org)/\(encoded(project))/_git/\(encoded(repo))/pullrequest/\(id)"
  }

  /// Web URL to create a PR for a branch.
  func createPRURL(sourceBranch: String, targetBranch: String?) -> String {
    var url = "https://dev.azure.com/\(org)/\(encoded(project))/_git/\(encoded(repo))/pullrequestcreate?sourceRef=\(encoded(sourceBranch))"
    if let targetBranch { url += "&targetRef=\(encoded(targetBranch))" }
    return url
  }

  private func encoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  /// Parses org/project/repo from a `git remote get-url origin` value.
  static func parse(_ remote: String?) -> AzureRemote? {
    guard var remote else { return nil }
    remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    if remote.hasSuffix(".git") { remote = String(remote.dropLast(4)) }

    // SSH: git@ssh.dev.azure.com:v3/{org}/{project}/{repo}
    if let range = remote.range(of: "ssh.dev.azure.com:v3/") {
      let parts = remote[range.upperBound...].split(separator: "/")
      if parts.count >= 3 {
        return AzureRemote(org: String(parts[0]), project: String(parts[1]), repo: String(parts[2]))
      }
      return nil
    }

    guard let comps = URLComponents(string: remote), let host = comps.host else { return nil }
    var segments = comps.path.split(separator: "/").map(String.init)
    // Drop a leading "DefaultCollection" some visualstudio.com URLs carry.
    if segments.first == "DefaultCollection" { segments.removeFirst() }

    if host.hasSuffix("visualstudio.com") {
      // https://{org}.visualstudio.com/{project}/_git/{repo}
      let org = String(host.split(separator: ".").first ?? "")
      guard let gitIdx = segments.firstIndex(of: "_git"), gitIdx > 0, gitIdx + 1 < segments.count else { return nil }
      return AzureRemote(org: org, project: segments[gitIdx - 1], repo: segments[gitIdx + 1])
    }

    if host == "dev.azure.com" {
      // https://dev.azure.com/{org}/{project}/_git/{repo}
      guard let gitIdx = segments.firstIndex(of: "_git"), gitIdx >= 2, gitIdx + 1 < segments.count else { return nil }
      return AzureRemote(org: segments[0], project: segments[gitIdx - 1], repo: segments[gitIdx + 1])
    }

    return nil
  }
}
