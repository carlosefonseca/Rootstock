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

  /// Build-validation statuses posted to a PR. This resource is preview-only.
  func prStatuses(remote: AzureRemote, prId: Int) async -> [ADOPRStatus] {
    let list = try? await client.get(ADOList<ADOPRStatus>.self, org: remote.org,
      path: "\(repoPath(remote))/pullRequests/\(prId)/statuses",
      apiVersion: "7.0-preview.1")
    return list?.value ?? []
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

  /// Work item detail from the (possibly different) work-item org.
  func workItem(org: String, id: String) async throws -> ADOWorkItem {
    try await client.get(ADOWorkItem.self, org: org,
      path: "_apis/wit/workitems/\(id)",
      query: ["fields": "System.Title,System.State,System.WorkItemType"])
  }
}

/// Resolves a work item id for a branch, in the plan's order.
enum WorkItemResolver {
  struct Resolution {
    var id: String
    var guessed: Bool
  }

  private static let urlRegex = try! NSRegularExpression(pattern: #"_workitems/edit/(\d+)"#)
  private static let branchRegex = try! NSRegularExpression(pattern: #"(\d{4,7})"#)

  static func resolve(config: BranchConfig, branch: String, prDescription: String?) -> Resolution? {
    // 1. Already recorded in the shared conf.
    if let id = config.workItemID, !id.isEmpty {
      return Resolution(id: id, guessed: false)
    }
    // 2. A work-item URL inside the PR description (the Ruby script's trick).
    if let description = prDescription, let id = firstMatch(urlRegex, in: description) {
      return Resolution(id: id, guessed: false)
    }
    // 3. A leading numeric token in the branch name — a labelled guess.
    if let id = firstMatch(branchRegex, in: branch) {
      return Resolution(id: id, guessed: true)
    }
    return nil
  }

  private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let group = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[group])
  }
}
