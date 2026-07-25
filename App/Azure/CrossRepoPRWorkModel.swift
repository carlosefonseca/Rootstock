import Foundation
import Observation

/// One Azure DevOps repo the app knows about — either a tracked clone's own
/// remote, or one of its submodules'.
struct RepoRef: Identifiable, Hashable {
  var org: String
  var project: String
  var repo: String
  var displayName: String
  var id: String { "\(org)/\(project)/\(repo)" }
}

/// Why a PR showed up in "my work" — one PR can have several.
struct PRWorkReason: Identifiable, Hashable {
  enum Kind: String {
    case needsReview
    case waitingResolved
    case hasReplies
    case failingOrConflict
  }
  var kind: Kind
  var detail: String
  var id: String { kind.rawValue + detail }
}

/// A pull request with the reasons it needs the user's attention.
struct PRWork: Identifiable {
  var repo: RepoRef
  var pr: ADOPullRequest
  var author: ADOIdentity?
  var reasons: [PRWorkReason]
  var relevantComments: [ADOComment]
  var id: String { "\(repo.id)#\(pr.pullRequestId)" }
}

/// Aggregates pull-request work across every tracked clone (and their
/// submodules): PRs to review, PRs the user is waiting on the author for that
/// now have resolved threads, the user's own comments that got a reply, and
/// the user's own PRs that are failing checks or have conflicts.
///
/// Lives for the app's lifetime (created once in `RootstockApp`, not per
/// window) so the toolbar badge reflects the last-known count even while the
/// PR-work window itself is closed.
@Observable
@MainActor
final class CrossRepoPRWorkModel {
  enum Phase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  private(set) var phase: Phase = .idle
  private(set) var items: [PRWork] = []
  /// Non-fatal per-repo failures (e.g. no credential for that org) — the rest
  /// of the refresh still completes.
  private(set) var repoErrors: [RepoRef: String] = [:]
  private(set) var lastRefreshed: Date?

  /// Distinct PRs needing attention — what the toolbar badge shows.
  var badgeCount: Int { Set(items.map(\.id)).count }

  private let service = AzureService()
  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  func refresh(clones: [TrackedClone]) {
    refreshTask?.cancel()
    refreshTask = Task { await self.performRefresh(clones: clones) }
  }

  /// Refreshes only if the last refresh is missing or older than `staleAfter`.
  func refreshIfStale(clones: [TrackedClone], staleAfter: TimeInterval = 300) {
    if let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < staleAfter { return }
    refresh(clones: clones)
  }

  private func performRefresh(clones: [TrackedClone]) async {
    phase = .loading
    let repos = await Self.discoverRepos(clones: clones)
    let orgs = Set(repos.map(\.org))

    var identities: [String: Result<ADOIdentity, Error>] = [:]
    await withTaskGroup(of: (String, Result<ADOIdentity, Error>).self) { group in
      for org in orgs {
        group.addTask {
          do { return (org, .success(try await self.service.client.currentIdentity(org: org))) }
          catch { return (org, .failure(error)) }
        }
      }
      for await (org, result) in group { identities[org] = result }
    }

    guard !Task.isCancelled else { return }

    var newItems: [PRWork] = []
    var newErrors: [RepoRef: String] = [:]
    await withTaskGroup(of: (RepoRef, [PRWork]?, String?).self) { group in
      for repo in repos {
        switch identities[repo.org] {
        case .success(let identity):
          group.addTask {
            do { return (repo, try await self.processRepo(repo: repo, identity: identity), nil) }
            catch { return (repo, nil, error.localizedDescription) }
          }
        case .failure(let error):
          newErrors[repo] = error.localizedDescription
        case nil:
          newErrors[repo] = "No credential for \(repo.org)."
        }
      }
      for await (repo, items, errorMessage) in group {
        if let items { newItems.append(contentsOf: items) }
        if let errorMessage { newErrors[repo] = errorMessage }
      }
    }

    guard !Task.isCancelled else { return }
    items = newItems.sorted {
      $0.repo.displayName == $1.repo.displayName
        ? $0.pr.pullRequestId < $1.pr.pullRequestId
        : $0.repo.displayName < $1.repo.displayName
    }
    repoErrors = newErrors
    lastRefreshed = .now
    phase = .loaded
  }

  /// Every repo the app knows about: each tracked clone's own remote, plus one
  /// level of its declared git submodules (not recursive).
  private static func discoverRepos(clones: [TrackedClone]) async -> [RepoRef] {
    var seen = Set<String>()
    var result: [RepoRef] = []
    func add(_ remote: AzureRemote?, displayName: String) {
      guard let remote else { return }
      let ref = RepoRef(org: remote.org, project: remote.project, repo: remote.repo, displayName: displayName)
      if seen.insert(ref.id).inserted { result.append(ref) }
    }
    for clone in clones {
      add(AzureRemote.parse(clone.remoteURL), displayName: clone.displayName)
      for submodule in await Git.submodules(in: clone.rootURL) {
        let name = URL(fileURLWithPath: submodule.path).lastPathComponent
        add(AzureRemote.parse(submodule.remoteURL), displayName: "\(clone.displayName) / \(name)")
      }
    }
    return result
  }

  private func processRepo(repo: RepoRef, identity: ADOIdentity) async throws -> [PRWork] {
    let remote = AzureRemote(org: repo.org, project: repo.project, repo: repo.repo)
    async let reviewerPRsTask = service.pullRequests(remote: remote, reviewerId: identity.id)
    async let creatorPRsTask = service.pullRequests(remote: remote, creatorId: identity.id)
    let reviewerPRs = try await reviewerPRsTask
    let creatorPRs = try await creatorPRsTask

    var byId: [Int: ADOPullRequest] = [:]
    for pr in reviewerPRs + creatorPRs { byId[pr.pullRequestId] = pr }
    let creatorIds = Set(creatorPRs.map(\.pullRequestId))

    return await withTaskGroup(of: PRWork?.self) { group in
      for (id, pr) in byId {
        let isCreator = creatorIds.contains(id)
        group.addTask {
          let threads = (try? await self.service.threads(remote: remote, prId: id)) ?? []
          let statuses = isCreator ? await self.service.pullRequestStatuses(remote: remote, prId: id) : []
          return Self.classify(repo: repo, pr: pr, identity: identity, threads: threads,
                               statuses: statuses, isCreator: isCreator)
        }
      }
      var results: [PRWork] = []
      for await item in group { if let item { results.append(item) } }
      return results
    }
  }

  private nonisolated static func classify(repo: RepoRef, pr: ADOPullRequest, identity: ADOIdentity,
                                threads: [ADOThread], statuses: [ADOStatus], isCreator: Bool) -> PRWork? {
    var reasons: [PRWorkReason] = []
    var relevantComments: [ADOComment] = []
    let reviewerEntry = pr.reviewers?.first { $0.id == identity.id }

    // Bucket: needs my review (drafts excluded).
    if let reviewerEntry, reviewerEntry.voteKind == .noVote, pr.isDraft != true, pr.status == "active" {
      reasons.append(PRWorkReason(kind: .needsReview, detail: "Awaiting your review"))
    }

    // Bucket: I'm "waiting for author" and at least one thread I commented in
    // is now fixed/closed. ADO exposes no timestamp on vote changes, so this
    // is an approximation of "resolved since I waited" rather than exact.
    if let reviewerEntry, reviewerEntry.voteKind == .waiting {
      let resolved = threads.filter { thread in
        thread.isDeleted != true && (thread.status == "fixed" || thread.status == "closed") &&
        (thread.comments?.contains { $0.author?.id == identity.id } ?? false)
      }
      if !resolved.isEmpty {
        reasons.append(PRWorkReason(kind: .waitingResolved,
          detail: "\(resolved.count) thread\(resolved.count == 1 ? "" : "s") you flagged now resolved"))
        relevantComments += resolved.flatMap { $0.comments ?? [] }.filter { $0.author?.id == identity.id }
      }
    }

    // Bucket: a comment I opened has a reply from someone else. Comment `id`
    // orders chronologically within a thread, so no date parsing is needed
    // (and AzureClient's plain JSONDecoder can't parse ADO's date format anyway).
    var replyCount = 0
    for thread in threads where thread.isDeleted != true {
      let comments = (thread.comments ?? []).filter { $0.commentType != "system" }.sorted { $0.id < $1.id }
      guard let mine = comments.first(where: { $0.author?.id == identity.id }) else { continue }
      if comments.contains(where: { $0.id > mine.id && $0.author?.id != identity.id }) {
        replyCount += 1
        relevantComments.append(mine)
      }
    }
    if replyCount > 0 {
      reasons.append(PRWorkReason(kind: .hasReplies,
        detail: "\(replyCount) of your comments got a reply"))
    }

    // Bucket: my own PR fails checks or has conflicts.
    if isCreator {
      if pr.mergeStatus == "conflicts" {
        reasons.append(PRWorkReason(kind: .failingOrConflict, detail: "Merge conflicts"))
      }
      let failing = statuses.filter { $0.state == "failed" || $0.state == "error" }
      if !failing.isEmpty {
        // ADO can report the same check name multiple times (retries/iterations).
        var seenNames = Set<String>()
        let names = failing.compactMap(\.context?.name).filter { seenNames.insert($0).inserted }.joined(separator: ", ")
        reasons.append(PRWorkReason(kind: .failingOrConflict,
          detail: names.isEmpty ? "Checks failing" : "Failing: \(names)"))
      }
    }

    guard !reasons.isEmpty else { return nil }
    return PRWork(repo: repo, pr: pr, author: pr.createdBy, reasons: reasons, relevantComments: relevantComments)
  }
}
