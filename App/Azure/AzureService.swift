import Foundation

/// High-level Azure DevOps operations built on `AzureClient`, mirroring the
/// endpoints and the two-org work-item trick from the team's Ruby script.
struct AzureService {
  var client = AzureClient()

  private func encode(_ segment: String) -> String {
    segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
  }

  private func repoPath(_ remote: AzureRemote) -> String {
    "\(encode(remote.project))/_apis/git/repositories/\(encode(remote.repo))"
  }

  /// The active PR whose source branch is `branch`, if any.
  func pullRequest(remote: AzureRemote, branch: String) async throws -> ADOPullRequest? {
    let list = try await client.get(ADOList<ADOPullRequest>.self, org: remote.org,
      path: "\(repoPath(remote))/pullrequests",
      query: [
        "searchCriteria.sourceRefName": "refs/heads/\(branch)",
        "searchCriteria.status": "active",
        "$top": "1",
      ])
    return list.value.first
  }

  /// Count of active/pending comment threads on a PR.
  func unresolvedCommentCount(remote: AzureRemote, prId: Int) async -> Int {
    let list = try? await client.get(ADOList<ADOThread>.self, org: remote.org,
      path: "\(repoPath(remote))/pullRequests/\(prId)/threads")
    return list?.value.filter { $0.isUnresolved && ($0.comments?.contains { $0.commentType != "system" } ?? false) }.count ?? 0
  }

  /// Latest build for a branch under the code org/project.
  func latestBuild(remote: AzureRemote, branch: String) async -> ADOBuild? {
    let list = try? await client.get(ADOList<ADOBuild>.self, org: remote.org,
      path: "\(encode(remote.project))/_apis/build/builds",
      query: [
        "branchName": "refs/heads/\(branch)",
        "$top": "1",
        "queryOrder": "finishTimeDescending",
      ])
    return list?.value.first
  }

  /// Work item detail from the (possibly different) work-item org. Scoped to
  /// `project` when known, which matters when the work items live in a different
  /// org/project than the code (the two-org setup).
  func workItem(org: String, project: String?, id: String) async throws -> ADOWorkItem {
    let path: String
    if let project, !project.isEmpty {
      path = "\(encode(project))/_apis/wit/workitems/\(id)"
    } else {
      path = "_apis/wit/workitems/\(id)"
    }
    return try await client.get(ADOWorkItem.self, org: org, path: path,
      query: ["fields": "System.Title,System.State,System.WorkItemType"])
  }
}

/// Finds a work-item link mentioned in a PR description that isn't already in
/// the branch's configured list — the same trick the team's Ruby script uses
/// to relate a PR to a work item, offered here as a one-click "Confirm"
/// suggestion rather than auto-added (the URL might be wrong, or point to a
/// related-but-different item).
enum WorkItemResolver {
  private static let urlRegex = try! NSRegularExpression(
    pattern: #"https://dev\.azure\.com/\S+?/_workitems/edit/\d+"#)

  static func detect(in prDescription: String?, excluding configured: [WorkItemURL]) -> WorkItemURL? {
    guard let prDescription else { return nil }
    let range = NSRange(prDescription.startIndex..., in: prDescription)
    guard let match = urlRegex.firstMatch(in: prDescription, range: range),
          let r = Range(match.range, in: prDescription),
          let detected = WorkItemURL.parse(String(prDescription[r])) else { return nil }
    return configured.contains(detected) ? nil : detected
  }
}
