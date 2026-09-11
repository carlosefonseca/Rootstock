import Foundation

/// Generates a short, human-readable branch slug from a work item title using
/// the `fm` CLI (an LLM front-end) when it's available on the user's PATH.
///
/// `fm` is optional: if it isn't installed the caller simply falls back to a
/// bare `<prefix>/<id>` branch, so this never blocks worktree creation.
enum SlugGenerator {
  /// Whether the `fm` binary resolves on the login-shell PATH. Cached after the
  /// first check since PATH doesn't change within a run.
  private static var cachedAvailability: Bool?

  static func isAvailable() async -> Bool {
    if let cachedAvailability { return cachedAvailability }
    let result = await ShellRunner.run("command -v fm")
    let available = result.succeeded && !result.trimmedOut.isEmpty
    cachedAvailability = available
    return available
  }

  /// Asks `fm` for a ~3-word ASCII, dash-separated slug summarizing `title`.
  /// Returns a git-ref-safe slug, or `nil` if `fm` is unavailable, fails, or
  /// returns nothing usable.
  static func slug(for title: String) async -> String? {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty, await isAvailable() else { return nil }

    let prompt = """
    create a slug with about 3 words that summarizes/rewords the following \
    title, using only ascii chars (no accents) and dashes instead of spaces. \
    If the title includes iOS, ignore it; only return the slug itself and only \
    in portuguese or english: "\(trimmedTitle)"
    """

    // Single-quote the prompt for the shell, escaping any embedded single
    // quotes (work item titles can contain apostrophes).
    let escaped = prompt.replacingOccurrences(of: "'", with: "'\\''")
    let result = await ShellRunner.run("fm respond '\(escaped)'")
    guard result.succeeded else { return nil }

    return sanitize(result.trimmedOut)
  }

  /// Normalizes whatever `fm` returns into a safe slug: strips surrounding
  /// quotes/whitespace, lowercases, folds non-ASCII to ASCII, collapses runs of
  /// non-alphanumeric characters to single dashes, and trims stray dashes.
  static func sanitize(_ raw: String) -> String? {
    // `fm` may return a multi-line explanation despite the instruction; take the
    // last non-empty line, which is where a bare slug tends to land.
    let line = raw
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last(where: { !$0.isEmpty }) ?? raw

    let ascii = line
      .folding(options: .diacriticInsensitive, locale: .init(identifier: "en_US"))
      .lowercased()

    let slug = ascii
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    return slug.isEmpty ? nil : slug
  }
}
