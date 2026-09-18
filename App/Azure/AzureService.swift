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

    // Compared by build id (monotonically increasing per org as builds are
    // queued), not finishTimeDate: a just-triggered build hasn't finished yet
    // so its finishTime is nil, which would otherwise always lose to an
    // already-completed build from the other source.
    var merged: [Int: (build: ADOBuild, source: BuildSource)] = [:]
    for (id, build) in latestBranch { merged[id] = (build, .branch) }
    for (id, build) in latestPR {
      if let existing = merged[id], existing.build.id > build.id {
        continue
      }
      merged[id] = (build, .pullRequest)
    }
    return Array(merged.values)
  }

  /// Queues a new run of `definitionId`.
  ///
  /// `sourceRef` decides what gets built, and it's the whole point of the
  /// distinction `latestBuildsByPipeline` already draws: queueing
  /// `refs/pull/<id>/merge` reruns the pipeline the way the PR's own validation
  /// build runs it (against the merged result), which is what an optional build
  /// policy on the PR is showing. `refs/heads/<branch>` just rebuilds the branch
  /// tip.
  ///
  /// Returns the queued build, already carrying its id, definition, and web URL
  /// so the caller can show it immediately.
  func queueBuild(remote: AzureRemote, definitionId: Int, sourceRef: String) async throws -> ADOBuild {
    try await client.post(ADOBuild.self, org: remote.org,
      path: "\(encode(remote.project))/_apis/build/builds",
      body: [
        "definition": ["id": definitionId],
        "sourceBranch": sourceRef,
      ])
  }

  /// The project's GUID, needed to address PR-scoped policy evaluations.
  func projectId(remote: AzureRemote) async throws -> String {
    let project = try await client.get(ADOProject.self, org: remote.org,
      path: "_apis/projects/\(encode(remote.project))")
    return project.id
  }

  /// The branch policies being evaluated against this PR — the "Checks" list on
  /// the PR page, required and optional alike.
  func policyEvaluations(remote: AzureRemote, projectId: String, prId: Int) async -> [ADOPolicyEvaluation] {
    let list = try? await client.get(ADOList<ADOPolicyEvaluation>.self, org: remote.org,
      path: "\(encode(remote.project))/_apis/policy/evaluations",
      query: ["artifactId": "vstfs:///CodeReview/CodeReviewId/\(projectId)/\(prId)"],
      apiVersion: "7.1-preview.1")
    return list?.value ?? []
  }

  /// Requeues one policy evaluation — the API behind the "Queue"/"Re-queue"
  /// link the PR page shows next to a build check. Unlike `queueBuild`, this
  /// runs the build *as the policy*, so the PR's own check entry updates rather
  /// than a detached build appearing beside it.
  func requeuePolicyEvaluation(remote: AzureRemote, evaluationId: String) async throws {
    try await client.patch(ADOPolicyEvaluation.self, org: remote.org,
      path: "\(encode(remote.project))/_apis/policy/evaluations/\(evaluationId)",
      apiVersion: "7.1-preview.1")
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
      query: ["fields": "System.Title,System.State,System.WorkItemType,System.Description"])
  }
}

/// Finds work-item links mentioned in a PR description that aren't already in
/// the branch's configured list — the same trick the team's Ruby script uses
/// to relate a PR to a work item. Detected items are shown automatically
/// (`AzureSection` renders them alongside configured ones, tagged "From PR"),
/// and "Add" just pins one into the branch's persisted config so it keeps
/// showing even if the description text changes later.
enum WorkItemResolver {
  private static let urlRegex = try! NSRegularExpression(
    pattern: #"https://dev\.azure\.com/\S+?/_workitems/edit/\d+"#)

  static func detect(in prDescription: String?, excluding configured: [WorkItemURL]) -> [WorkItemURL] {
    LinkResolver.matches(of: urlRegex, in: prDescription)
      .compactMap { WorkItemURL.parse($0) }
      .filter { !configured.contains($0) }
      .uniqued()
  }
}

/// Finds pull-request links mentioned in a PR description that aren't already
/// in the branch's configured "additional PR" list and don't just point back
/// at the branch's own PR — the PR-description analogue of `WorkItemResolver`.
enum PullRequestResolver {
  private static let urlRegex = try! NSRegularExpression(
    pattern: #"https://dev\.azure\.com/\S+?/pullrequest/\d+"#)
  /// Azure DevOps' `!12345` shorthand for linking another PR in the same repo —
  /// stored as plain text in the description (unlike a pasted link), so it
  /// needs its own pattern. The lookbehind avoids matching mid-word (e.g. a
  /// stray "x!123") and a leading "!!123".
  private static let mentionRegex = try! NSRegularExpression(
    pattern: #"(?<![\w!])!(\d{1,6})\b"#)

  /// `remote` is the branch's own PR's repo — the shorthand mention carries no
  /// org/project/repo of its own, so it's resolved against the repo the
  /// description was written in.
  static func detect(in prDescription: String?, excluding configured: [PullRequestURL],
                      selfPR: PullRequestURL?, remote: AzureRemote?) -> [PullRequestURL] {
    var found = LinkResolver.matches(of: urlRegex, in: prDescription).compactMap { PullRequestURL.parse($0) }
    if let remote {
      let mentioned = LinkResolver.matches(of: mentionRegex, in: prDescription).compactMap { match -> PullRequestURL? in
        guard let id = Int(match.dropFirst()) else { return nil }
        return PullRequestURL(org: remote.org, project: remote.project, repo: remote.repo, id: id)
      }
      found.append(contentsOf: mentioned)
    }
    return found
      .filter { !configured.contains($0) && $0 != selfPR }
      .uniqued()
  }
}

/// Finds the first Figma link mentioned in a work item's (HTML) description,
/// so design work is reachable straight from the work item card without
/// requiring it to be separately bookmarked.
enum FigmaLinkResolver {
  private static let urlRegex = try! NSRegularExpression(
    pattern: #"https://(?:www\.)?figma\.com/[^\s"'<>]+"#)

  static func detect(in descriptionHTML: String?) -> String? {
    LinkResolver.matches(of: urlRegex, in: descriptionHTML).first?
      .replacingOccurrences(of: "&amp;", with: "&")
  }
}

private enum LinkResolver {
  static func matches(of regex: NSRegularExpression, in text: String?) -> [String] {
    guard let text else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard let r = Range(match.range, in: text) else { return nil }
      return String(text[r])
    }
  }
}

private extension Array where Element: Hashable {
  /// First-occurrence-wins de-duplication — a description can link the same
  /// item more than once.
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
