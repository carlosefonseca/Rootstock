import Foundation
import Observation

/// Traces the refresh pipeline to stderr — repos discovered, identity
/// resolved per org, raw PR counts per repo, and why each individual PR was
/// or wasn't included. Invisible during normal GUI use; only shows up when
/// launched from Terminal or inspected via Console. Kept permanently since
/// this is exactly the kind of thing that's only reproducible on someone
/// else's machine (a specific org/identity/auth combination), where the only
/// way to diagnose a "why didn't my PR show up" report is to have them run a
/// build with this and send back the output.
private func debugLog(_ message: String) {
  FileHandle.standardError.write("DEBUG PRWork: \(message)\n".data(using: .utf8)!)
}

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

  /// PRWork.id -> the reason signature it had when marked done. Keyed by
  /// signature (not just id) so a dismissed PR reappears automatically if
  /// something new happens on it (e.g. a fresh reply after you dismissed it
  /// for being approved) rather than staying hidden forever.
  private(set) var dismissed: [String: String] = [:]
  private static let dismissedKey = "prWork.dismissed"

  /// What the window actually lists — `items` with dismissed-and-unchanged
  /// PRs filtered out.
  var visibleItems: [PRWork] { items.filter { dismissed[$0.id] != Self.signature(for: $0) } }
  /// Distinct PRs needing attention — what the toolbar badge shows.
  var badgeCount: Int { Set(visibleItems.map(\.id)).count }

  private let service = AzureService()
  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.dismissedKey),
       let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
      dismissed = decoded
    }
  }

  func markDone(_ item: PRWork) {
    dismissed[item.id] = Self.signature(for: item)
    saveDismissed()
  }

  func unmarkDone(_ id: String) {
    dismissed[id] = nil
    saveDismissed()
  }

  private func saveDismissed() {
    guard let data = try? JSONEncoder().encode(dismissed) else { return }
    UserDefaults.standard.set(data, forKey: Self.dismissedKey)
  }

  private static func signature(for item: PRWork) -> String {
    item.reasons.map(\.id).sorted().joined(separator: "|")
  }

  /// Set synchronously in `refresh()`, not inside `performRefresh` — both the
  /// main window and the PR Work window (if it auto-reopened from window
  /// restoration) call `refreshIfStale` independently on launch, and since
  /// neither `lastRefreshed` nor any in-flight state exists yet at that exact
  /// moment, they'd otherwise both pass the staleness check and each call
  /// `refresh()`, repeatedly cancelling each other (visible as a string of
  /// "-999 cancelled" network errors) before either ever completes. Flipping
  /// this flag before the new Task is even created — not from inside it —
  /// closes that race: whichever call reaches here first wins, synchronously,
  /// within the same MainActor turn.
  private(set) var isRefreshing = false

  func refresh(clones: [TrackedClone]) {
    refreshTask?.cancel()
    isRefreshing = true
    refreshTask = Task {
      await self.performRefresh(clones: clones)
      self.isRefreshing = false
    }
  }

  /// Refreshes only if the last refresh is missing or older than `staleAfter`
  /// — and only if nothing is already in flight, so opportunistic callers
  /// (a window appearing) never race each other. An explicit `refresh()` call
  /// (the Refresh button, Cmd+R) still always cancels-and-restarts.
  func refreshIfStale(clones: [TrackedClone], staleAfter: TimeInterval = 300) {
    guard !isRefreshing else { return }
    if let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < staleAfter { return }
    refresh(clones: clones)
  }

  private func performRefresh(clones: [TrackedClone]) async {
    phase = .loading
    let repos = await Self.discoverRepos(clones: clones)
    debugLog("discovered \(repos.count) repos: \(repos.map(\.id))")
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
    for (org, result) in identities {
      switch result {
      case .success(let identity): debugLog("identity for \(org): \(identity.id) (\(identity.name))")
      case .failure(let error): debugLog("identity FAILED for \(org): \(error)")
      }
    }

    guard !Task.isCancelled else { debugLog("cancelled after identity resolution"); return }

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
        debugLog("repo \(repo.id): \(items?.count ?? 0) items\(errorMessage.map { " ERROR: \($0)" } ?? "")")
        if let items { newItems.append(contentsOf: items) }
        if let errorMessage { newErrors[repo] = errorMessage }
      }
    }

    guard !Task.isCancelled else { debugLog("cancelled after repo processing"); return }
    debugLog("total newItems=\(newItems.count)")
    items = newItems.sorted {
      $0.repo.displayName == $1.repo.displayName
        ? $0.pr.pullRequestId < $1.pr.pullRequestId
        : $0.repo.displayName < $1.repo.displayName
    }
    // Drop dismissals for PRs that no longer show up at all (closed, merged,
    // no longer flagged) so this doesn't grow forever.
    let currentIds = Set(items.map(\.id))
    dismissed = dismissed.filter { currentIds.contains($0.key) }
    saveDismissed()
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
    debugLog("\(repo.id): reviewerPRs=\(reviewerPRs.count) creatorPRs=\(creatorPRs.count)")

    var byId: [Int: ADOPullRequest] = [:]
    for pr in reviewerPRs + creatorPRs { byId[pr.pullRequestId] = pr }
    let creatorIds = Set(creatorPRs.map(\.pullRequestId))

    return await withTaskGroup(of: (Int, PRWork?).self) { group in
      for (id, pr) in byId {
        let isCreator = creatorIds.contains(id)
        group.addTask {
          let rawThreads = (try? await self.service.threads(remote: remote, prId: id)) ?? []
          // ADO's threads endpoint can list the same thread more than once —
          // it's associated with the PR iteration(s) it was raised against,
          // and a thread spanning multiple iterations comes back once per
          // iteration. Dedupe by thread id before counting/displaying.
          var seenThreadIds = Set<Int>()
          let threads = rawThreads.filter { seenThreadIds.insert($0.id).inserted }
          let statuses = isCreator ? await self.service.pullRequestStatuses(remote: remote, prId: id) : []
          return (id, Self.classify(repo: repo, pr: pr, identity: identity, threads: threads,
                                    statuses: statuses, isCreator: isCreator))
        }
      }
      var results: [PRWork] = []
      for await (id, item) in group {
        debugLog("\(repo.id) #\(id): \(item == nil ? "no reason (not included)" : "INCLUDED")")
        if let item { results.append(item) }
      }
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
      // codecoverage is noisy/expected-to-fail here and isn't actionable, so
      // it's excluded rather than surfaced as something to fix.
      let failing = statuses.filter {
        ($0.state == "failed" || $0.state == "error") && $0.context?.name?.lowercased() != "codecoverage"
      }
      if !failing.isEmpty {
        // ADO can report the same check name multiple times (retries/iterations).
        var seenNames = Set<String>()
        let names = failing.compactMap(\.context?.name).filter { seenNames.insert($0).inserted }.joined(separator: ", ")
        reasons.append(PRWorkReason(kind: .failingOrConflict,
          detail: names.isEmpty ? "Checks failing" : "Failing: \(names)"))
      }
    }

    if reasons.isEmpty {
      let reviewerEntry = pr.reviewers?.first { $0.id == identity.id }
      debugLog("classify \(repo.id) #\(pr.pullRequestId): no reasons — " +
        "reviewerEntry=\(reviewerEntry.map { "\($0.displayName) vote=\($0.vote) voteKind=\($0.voteKind)" } ?? "nil") " +
        "isDraft=\(String(describing: pr.isDraft)) status=\(pr.status) isCreator=\(isCreator) " +
        "mergeStatus=\(String(describing: pr.mergeStatus)) statuses.count=\(statuses.count)")
      return nil
    }
    // A thread that's both "resolved" and "has a reply" contributes its
    // comment via both buckets above — comment `id` is only unique within its
    // own thread (every thread's first comment is id 1), so dedupe on
    // (id, content) together rather than id alone.
    var seenComments = Set<String>()
    let dedupedComments = relevantComments.filter { seenComments.insert("\($0.id)|\($0.content ?? "")").inserted }
    return PRWork(repo: repo, pr: pr, author: pr.createdBy, reasons: reasons, relevantComments: dedupedComments)
  }
}
