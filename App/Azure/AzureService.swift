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

  /// A single PR by id, regardless of its source branch or status — how
  /// manually-attached "additional" PRs (e.g. the work was split across
  /// several PRs) are fetched, as opposed to `pullRequest(remote:branch:)`
  /// which only finds the one active PR for the checked-out branch.
  func pullRequest(remote: AzureRemote, id: Int) async throws -> ADOPullRequest {
    try await client.get(ADOPullRequest.self, org: remote.org, path: "\(repoPath(remote))/pullRequests/\(id)")
  }

  /// Active pull requests where `identity` is a reviewer and/or the creator.
  /// Per-repo search — not the org-wide `_apis/git/pullrequests` endpoint —
  /// since this app deliberately scopes everything to tracked repos.
  func pullRequests(remote: AzureRemote, reviewerId: String? = nil, creatorId: String? = nil,
                     status: String = "active") async throws -> [ADOPullRequest] {
    var query: [String: String] = ["searchCriteria.status": status, "$top": "200"]
    if let reviewerId { query["searchCriteria.reviewerId"] = reviewerId }
    if let creatorId { query["searchCriteria.creatorId"] = creatorId }
    let list = try await client.get(ADOList<ADOPullRequest>.self, org: remote.org,
      path: "\(repoPath(remote))/pullrequests", query: query)
    return list.value
  }

  /// Full thread + comment detail for a PR.
  func threads(remote: AzureRemote, prId: Int) async throws -> [ADOThread] {
    let list = try await client.get(ADOList<ADOThread>.self, org: remote.org,
      path: "\(repoPath(remote))/pullRequests/\(prId)/threads")
    return list.value
  }

  /// Build/test/policy status checks attached to the PR itself (not the branch).
  func pullRequestStatuses(remote: AzureRemote, prId: Int) async -> [ADOStatus] {
    let list = try? await client.get(ADOList<ADOStatus>.self, org: remote.org,
      path: "\(repoPath(remote))/pullRequests/\(prId)/statuses")
    return list?.value ?? []
  }

  /// Count of active/pending comment threads on a PR.
  func unresolvedCommentCount(remote: AzureRemote, prId: Int) async -> Int {
    let list = try? await threads(remote: remote, prId: prId)
    return list?.filter { $0.isUnresolved && ($0.comments?.contains { $0.commentType != "system" } ?? false) }.count ?? 0
  }

  /// Recent builds queued against `branchName`, most recently finished first.
  private func builds(remote: AzureRemote, branchName: String, top: Int) async -> [ADOBuild] {
    let list = try? await client.get(ADOList<ADOBuild>.self, org: remote.org,
      path: "\(encode(remote.project))/_apis/build/builds",
      query: [
        "branchName": branchName,
        "$top": String(top),
        "queryOrder": "finishTimeDescending",
      ])
    return list?.value ?? []
  }

  enum BuildSource { case pullRequest, branch }

  /// The latest build for each pipeline definition that has run against this
  /// branch or PR. Plain branch-push builds (`refs/heads/<branch>`) only
  /// reflect a CI trigger firing on push, which isn't necessarily the build
  /// Azure Pipelines ran to validate the PR itself — PR builds (build-validation
  /// policies, `pr:` triggers) run against the PR's merge ref
  /// (`refs/pull/<id>/merge`) instead. This merges both so each pipeline shows
  /// its single most relevant recent run, tagged with where it came from.
  func latestBuildsByPipeline(remote: AzureRemote, branch: String, prId: Int?) async -> [(build: ADOBuild, source: BuildSource)] {
    async let branchBuilds = builds(remote: remote, branchName: "refs/heads/\(branch)", top: 50)
    let prBuilds: [ADOBuild]
    if let prId {
      prBuilds = await builds(remote: remote, branchName: "refs/pull/\(prId)/merge", top: 50)
    } else {
      prBuilds = []
    }

    // Each list is already ordered most-recently-finished first, so the first
    // occurrence of a definition id within a list is that source's latest.
    func firstPerDefinition(_ list: [ADOBuild]) -> [Int: ADOBuild] {
      var result: [Int: ADOBuild] = [:]
      for build in list {
        guard let id = build.definition?.id, result[id] == nil else { continue }
        result[id] = build
      }
      return result
    }

    let latestBranch = firstPerDefinition(await branchBuilds)
    let latestPR = firstPerDefinition(prBuilds)

    var merged: [Int: (build: ADOBuild, source: BuildSource)] = [:]
    for (id, build) in latestBranch { merged[id] = (build, .branch) }
    for (id, build) in latestPR {
      if let existing = merged[id], (existing.build.finishTimeDate ?? .distantPast) > (build.finishTimeDate ?? .distantPast) {
        continue
      }
      merged[id] = (build, .pullRequest)
    }
    return Array(merged.values)
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
