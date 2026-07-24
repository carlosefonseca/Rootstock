import Foundation

/// A self-documenting Makefile target: `name: deps ## description`.
struct MakeTarget: Identifiable, Hashable {
  var name: String
  var help: String
  var id: String { name }
}

/// Parses targets the same way the repo's own `help` target does — matching the
/// trailing `## description` convention the team already writes.
enum MakefileParser {
  // Mirrors: ^([A-Za-z0-9_.-]+):.*?##\s*(.*)$
  private static let regex = try! NSRegularExpression(
    pattern: #"^([A-Za-z0-9_.-]+):.*?##\s*(.*)$"#)

  /// Reads `Makefile` (and any `*.mk` includes) in `directory`, in declaration order.
  static func targets(in directory: URL) -> [MakeTarget] {
    let fm = FileManager.default
    var files: [URL] = []
    for name in ["Makefile", "Makefile.local"] {
      let url = directory.appending(path: name)
      if fm.fileExists(atPath: url.path) { files.append(url) }
    }
    if let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      files.append(contentsOf: entries.filter { $0.pathExtension == "mk" }.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    var targets: [MakeTarget] = []
    var seen = Set<String>()
    for file in files {
      guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
      for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let nameRange = Range(match.range(at: 1), in: line),
              let helpRange = Range(match.range(at: 2), in: line) else { continue }
        let name = String(line[nameRange])
        guard !seen.contains(name) else { continue }
        seen.insert(name)
        targets.append(MakeTarget(name: name,
                                  help: String(line[helpRange]).trimmingCharacters(in: .whitespaces)))
      }
    }
    return targets
  }

  static func hasMakefile(in directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: directory.appending(path: "Makefile").path)
  }
}
