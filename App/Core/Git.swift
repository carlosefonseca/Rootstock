import Foundation

/// A worktree as reported by `git worktree list --porcelain`.
struct WorktreeInfo: Identifiable, Hashable {
  var path: String
  var branch: String?      // short name, e.g. "feature/205552-payment-state"
  var head: String?        // commit sha
  var isDetached: Bool
  var isBare: Bool

  var id: String { path }
  var url: URL { URL(fileURLWithPath: path) }
  var folderName: String { url.lastPathComponent }
  var displayBranch: String { branch ?? (isDetached ? "detached" : (isBare ? "bare" : "—")) }
}

/// Working-tree status derived from `git status --porcelain=v2 --branch`, with
/// ahead/behind tracked separately for the remote upstream and the parent branch.
struct WorktreeStatus: Hashable {
  var branch: String?

  var hasUpstream = false
  var remoteAhead = 0
  var remoteBehind = 0

  var hasBase = false
  var baseName: String?
  var baseAhead = 0
  var baseBehind = 0

  var staged = 0
  var unstaged = 0
  var untracked = 0
  var conflicted = 0

  var isClean: Bool { staged == 0 && unstaged == 0 && untracked == 0 && conflicted == 0 }
  var changedCount: Int { staged + unstaged + untracked + conflicted }

  enum Dot: Hashable { case clean, dirty, ahead, behind, diverged, conflicted }

  /// The single dot shown in the sidebar, prioritising the most urgent signal.
  /// Ahead/behind uses the upstream when present, otherwise the parent branch.
  var dot: Dot {
    if conflicted > 0 { return .conflicted }
    if !isClean { return .dirty }
    let ahead = hasUpstream ? remoteAhead : baseAhead
    let behind = hasUpstream ? remoteBehind : baseBehind
    if ahead > 0 && behind > 0 { return .diverged }
    if ahead > 0 { return .ahead }
    if behind > 0 { return .behind }
    return .clean
  }
}

/// A submodule declared in `.gitmodules`, read statically from the config file
/// so this works even for uninitialized submodules — only their declared
/// identity (path/remote) is needed, not their checked-out content.
struct GitSubmodule: Identifiable, Hashable {
  var path: String
  var remoteURL: String?
  var id: String { path }
}

/// Thin async wrapper over the system `git`.
enum Git {
  /// Validates that `directory` is inside a git working tree.
  static func isRepository(_ directory: URL) async -> Bool {
    let result = await ShellRunner.run("git rev-parse --is-inside-work-tree", in: directory)
    return result.succeeded && result.trimmedOut == "true"
  }

  /// Absolute path of the repository's common `.git` root, used to identify a clone.
  static func commonDir(_ directory: URL) async -> String? {
    let result = await ShellRunner.run("git rev-parse --path-format=absolute --git-common-dir", in: directory)
    return result.succeeded ? result.trimmedOut : nil
  }

  static func remoteURL(_ directory: URL) async -> String? {
    let result = await ShellRunner.run("git remote get-url origin", in: directory)
    return result.succeeded && !result.trimmedOut.isEmpty ? result.trimmedOut : nil
  }

  /// Parses `git worktree list --porcelain` into structured rows.
  static func worktrees(in directory: URL) async -> [WorktreeInfo] {
    let result = await ShellRunner.run("git worktree list --porcelain", in: directory)
    guard result.succeeded else { return [] }

    var infos: [WorktreeInfo] = []
    var current: WorktreeInfo?

    func flush() {
      if let current { infos.append(current) }
      current = nil
    }

    for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if line.hasPrefix("worktree ") {
        flush()
        current = WorktreeInfo(path: String(line.dropFirst("worktree ".count)),
                               branch: nil, head: nil, isDetached: false, isBare: false)
      } else if line.hasPrefix("HEAD ") {
        current?.head = String(line.dropFirst("HEAD ".count))
      } else if line.hasPrefix("branch ") {
        let ref = String(line.dropFirst("branch ".count))
        current?.branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
      } else if line == "detached" {
        current?.isDetached = true
      } else if line == "bare" {
        current?.isBare = true
      }
    }
    flush()
    return infos
  }

  /// Working-tree status plus ahead/behind against an optional base branch.
  static func status(in directory: URL, base: String?) async -> WorktreeStatus {
    var status = WorktreeStatus()
    let result = await ShellRunner.run("git status --porcelain=v2 --branch", in: directory)
    guard result.succeeded else { return status }

    for rawLine in result.stdout.split(separator: "\n") {
      let line = String(rawLine)
      if line.hasPrefix("# branch.head ") {
        status.branch = String(line.dropFirst("# branch.head ".count))
      } else if line.hasPrefix("# branch.ab ") {
        status.hasUpstream = true
        let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
        for part in parts {
          if part.hasPrefix("+") { status.remoteAhead = Int(part.dropFirst()) ?? 0 }
          if part.hasPrefix("-") { status.remoteBehind = Int(part.dropFirst()) ?? 0 }
        }
      } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
        // XY field: index 2..<4, e.g. "M." staged, ".M" unstaged.
        let xy = Array(line.dropFirst(2).prefix(2))
        if xy.count == 2 {
          if xy[0] != "." { status.staged += 1 }
          if xy[1] != "." { status.unstaged += 1 }
        }
      } else if line.hasPrefix("u ") {
        status.conflicted += 1
      } else if line.hasPrefix("? ") {
        status.untracked += 1
      }
    }

    // Ahead/behind versus the configured parent branch, in addition to the remote.
    if let base, !base.isEmpty {
      status.hasBase = true
      status.baseName = base.replacingOccurrences(of: "origin/", with: "")
      let rev = await ShellRunner.run(
        "git rev-list --left-right --count \(base)...HEAD", in: directory)
      if rev.succeeded {
        let parts = rev.trimmedOut.split(whereSeparator: { $0 == "\t" || $0 == " " })
        if parts.count == 2 {
          status.baseBehind = Int(parts[0]) ?? 0
          status.baseAhead = Int(parts[1]) ?? 0
        }
      }
    }
    return status
  }

  static func fetch(in directory: URL) async -> ShellResult {
    await ShellRunner.run("git fetch", in: directory)
  }

  /// Local and `origin` remote branch short-names, for picking an existing branch.
  ///
  /// `refs/remotes/origin/HEAD` is excluded explicitly rather than by filtering
  /// the short name: it shortens to plain `origin` (not `origin/HEAD`), so a
  /// suffix check misses it and a bogus "origin" entry ends up in the picker.
  static func branches(in directory: URL) async -> (local: [String], remote: [String]) {
    async let localResult = ShellRunner.run(
      "git for-each-ref --format='%(refname:short)' refs/heads", in: directory)
    async let remoteResult = ShellRunner.run(
      "git for-each-ref --format='%(refname:short)' --exclude=refs/remotes/origin/HEAD refs/remotes/origin",
      in: directory)

    func parse(_ result: ShellResult) -> [String] {
      result.stdout
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
        .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
    }
    return (parse(await localResult), parse(await remoteResult))
  }

  /// One level of direct submodules declared in `directory`'s `.gitmodules`.
  /// Fails cleanly to `[]` when there's no `.gitmodules` (non-zero exit).
  static func submodules(in directory: URL) async -> [GitSubmodule] {
    let result = await ShellRunner.run(
      "git config --file .gitmodules --get-regexp '\\.(path|url)$'", in: directory)
    guard result.succeeded else { return [] }

    var paths: [String: String] = [:]   // submodule name -> path
    var urls: [String: String] = [:]    // submodule name -> url

    for rawLine in result.stdout.split(separator: "\n") {
      let parts = rawLine.split(separator: " ", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let key = String(parts[0])
      let value = String(parts[1])
      guard key.hasPrefix("submodule."), let lastDot = key.lastIndex(of: ".") else { continue }
      let name = String(key[key.index(key.startIndex, offsetBy: "submodule.".count)..<lastDot])
      if key.hasSuffix(".path") { paths[name] = value }
      else if key.hasSuffix(".url") { urls[name] = value }
    }
    return paths.map { GitSubmodule(path: $0.value, remoteURL: urls[$0.key]) }
  }

  /// Removes a linked worktree. Run from `directory` (the main worktree/clone
  /// root), never from inside `path` itself, which is about to be deleted.
  /// `force` is needed when the worktree has uncommitted changes — plain
  /// `git worktree remove` refuses those.
  static func removeWorktree(_ path: String, in directory: URL, force: Bool) async -> ShellResult {
    let flag = force ? "--force " : ""
    return await ShellRunner.run("git worktree remove \(flag)'\(path)'", in: directory)
  }

  static func lastFetch(in directory: URL) async -> Date? {
    let common = await commonDir(directory) ?? directory.appending(path: ".git").path
    let fetchHead = URL(fileURLWithPath: common).appending(path: "FETCH_HEAD")
    let attrs = try? FileManager.default.attributesOfItem(atPath: fetchHead.path)
    return attrs?[.modificationDate] as? Date
  }
}
