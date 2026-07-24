import Foundation

extension Notification.Name {
  /// Posted after `SharedConfigEditor` saves — either the per-branch conf or the
  /// repo-wide `.dcdp/config.toml` — so `AzureSection` knows to re-fetch instead
  /// of continuing to show whatever it resolved before the edit.
  static let branchConfigChanged = Notification.Name("rootstock.branchConfigChanged")
}

/// The tracked, shared-by-default per-branch config stored under
/// `Scripts/branch-sync/<branch>.conf` — the same file `branch-sync.sh` writes,
/// extended with work-item / Figma / Slack keys. Slashes in the branch name are
/// encoded as `__`, matching the existing convention.
struct BranchConfig {
  // Existing branch-sync keys.
  var prjDep: String?      // PRJ_DEP — base/dependency branch
  var dsBranch: String?    // DS_BRANCH
  var dsDep: String?       // DS_DEP
  // New Rootstock keys (shared).
  var workItemURLs: [String] = []  // WORK_ITEM_URLS — comma-separated full URLs
  var figmaURL: String?    // FIGMA_URL
  var slackChannelURL: String? // SLACK_CHANNEL_URL

  /// Lines from the file we don't recognise, preserved verbatim on write so a
  /// round-trip (here or in `branch-sync.sh` once its `save_conf` is fixed)
  /// never drops fields the other tool owns.
  private var passthrough: [String] = []

  private static let known = ["PRJ_DEP", "DS_BRANCH", "DS_DEP",
                              "WORK_ITEM_URLS", "FIGMA_URL", "SLACK_CHANNEL_URL"]

  static func fileName(forBranch branch: String) -> String {
    branch.replacingOccurrences(of: "/", with: "__") + ".conf"
  }

  /// Directory holding the conf files for a worktree, honouring a
  /// `BRANCH_CONFIG_DIR` override from `.dcdp/config.toml`.
  static func directory(forWorktree worktree: URL) -> URL {
    if let override = DcdpConfig.load(worktree: worktree)?.branchConfigDir, !override.isEmpty {
      return worktree.appending(path: override)
    }
    return worktree.appending(path: "Scripts/branch-sync")
  }

  static func fileURL(worktree: URL, branch: String) -> URL {
    directory(forWorktree: worktree).appending(path: fileName(forBranch: branch))
  }

  /// Loads the conf for `branch`, or an empty config if none exists yet.
  static func load(worktree: URL, branch: String) -> BranchConfig {
    let url = fileURL(worktree: worktree, branch: branch)
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      return BranchConfig()
    }
    var config = BranchConfig()
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let eq = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#") else {
        if !line.isEmpty { config.passthrough.append(line) }
        continue
      }
      let key = String(trimmed[..<eq])
      guard known.contains(key) else {
        config.passthrough.append(line)
        continue
      }
      let value = unquote(String(trimmed[trimmed.index(after: eq)...]))
      switch key {
      case "PRJ_DEP": config.prjDep = value
      case "DS_BRANCH": config.dsBranch = value
      case "DS_DEP": config.dsDep = value
      case "WORK_ITEM_URLS":
        config.workItemURLs = value.split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
      case "FIGMA_URL": config.figmaURL = value
      case "SLACK_CHANNEL_URL": config.slackChannelURL = value
      default: break
      }
    }
    return config
  }

  /// Writes the conf, creating the directory if needed and preserving any
  /// passthrough lines (the `save_conf()` behaviour that branch-sync.sh needs).
  func save(worktree: URL, branch: String) throws {
    let dir = Self.directory(forWorktree: worktree)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var lines = ["# branch-sync config for: \(branch)"]
    func emit(_ key: String, _ value: String?) {
      guard let value, !value.isEmpty else { return }
      lines.append("\(key)=\"\(value)\"")
    }
    emit("PRJ_DEP", prjDep)
    emit("DS_BRANCH", dsBranch)
    emit("DS_DEP", dsDep)
    if !workItemURLs.isEmpty { lines.append("WORK_ITEM_URLS=\"\(workItemURLs.joined(separator: ","))\"") }
    emit("FIGMA_URL", figmaURL)
    emit("SLACK_CHANNEL_URL", slackChannelURL)
    lines.append(contentsOf: passthrough)

    let url = Self.fileURL(worktree: worktree, branch: branch)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  private static func unquote(_ value: String) -> String {
    var v = value.trimmingCharacters(in: .whitespaces)
    if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
      v = String(v.dropFirst().dropLast())
    }
    return v
  }
}

/// The tracked, repo-wide `.dcdp/config.toml` — applies to every branch/worktree
/// of the clone (read from the clone's main worktree, not whichever branch is
/// currently checked out), unlike the per-branch `branch-sync` conf.
struct DcdpConfig {
  var branchConfigDir: String?

  /// Lines this type doesn't recognise, preserved verbatim on save.
  private var passthrough: [String] = []
  private static let known = ["BRANCH_CONFIG_DIR"]

  static func fileURL(worktree: URL) -> URL {
    worktree.appending(path: ".dcdp/config.toml")
  }

  static func load(worktree: URL) -> DcdpConfig? {
    guard let contents = try? String(contentsOf: fileURL(worktree: worktree), encoding: .utf8) else { return nil }
    var config = DcdpConfig()
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let eq = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#") else {
        if !line.isEmpty { config.passthrough.append(line) }
        continue
      }
      let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
      guard known.contains(key) else {
        config.passthrough.append(line)
        continue
      }
      let value = unquote(String(trimmed[trimmed.index(after: eq)...]))
      switch key {
      case "BRANCH_CONFIG_DIR": config.branchConfigDir = value
      default: break
      }
    }
    return config
  }

  /// Writes `.dcdp/config.toml` at the repo root, creating the directory if
  /// needed and preserving any lines this type doesn't own.
  func save(worktree: URL) throws {
    let url = Self.fileURL(worktree: worktree)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var lines = ["# Rootstock repo config — applies to every branch/worktree of this clone."]
    func emit(_ key: String, _ value: String?) {
      guard let value, !value.isEmpty else { return }
      lines.append("\(key) = \"\(value)\"")
    }
    emit("BRANCH_CONFIG_DIR", branchConfigDir)
    lines.append(contentsOf: passthrough)

    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  private static func unquote(_ value: String) -> String {
    var v = value.trimmingCharacters(in: .whitespaces)
    if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
      v = String(v.dropFirst().dropLast())
    }
    return v
  }
}
