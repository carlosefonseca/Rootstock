import Foundation

/// A parsed Azure DevOps work item URL. Org, project, and id all come straight
/// from the URL itself — pasting a link is how the user tells Rootstock about
/// a work item, instead of separately configuring which org/project a repo's
/// work items live in (they're frequently not the same org as the code).
struct WorkItemURL: Equatable, Hashable {
  var org: String
  var project: String?
  var id: String

  /// The canonical URL for this work item — used both to normalize whatever
  /// shape was pasted before writing it back to the shared config, and to open
  /// it in a browser/tab.
  var canonical: String {
    guard let project, !project.isEmpty else {
      return "https://dev.azure.com/\(org)/_workitems/edit/\(id)"
    }
    let encodedProject = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
    return "https://dev.azure.com/\(org)/\(encodedProject)/_workitems/edit/\(id)"
  }

  /// Parses a pasted Azure DevOps work item URL — the current `dev.azure.com`
  /// form or the legacy `{org}.visualstudio.com` form, with or without a
  /// project segment, and both the `_workitems/edit/{id}` path shape and the
  /// `_boards/board/...?workitem={id}` query-param shape.
  static func parse(_ input: String) -> WorkItemURL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host else { return nil }

    var segments = url.pathComponents.filter { $0 != "/" }.map { $0.removingPercentEncoding ?? $0 }
    if segments.first == "DefaultCollection" { segments.removeFirst() }

    let org: String
    if host == "dev.azure.com" {
      guard !segments.isEmpty else { return nil }
      org = segments.removeFirst()
    } else if host.hasSuffix(".visualstudio.com") {
      org = String(host.split(separator: ".").first ?? "")
    } else {
      return nil
    }

    if let editIdx = segments.firstIndex(of: "edit"), editIdx > 0, segments[editIdx - 1] == "_workitems",
       editIdx + 1 < segments.count {
      let id = segments[editIdx + 1]
      let project = editIdx > 1 ? segments[0] : nil
      return WorkItemURL(org: org, project: project, id: id)
    }
    if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
       let id = queryItems.first(where: { $0.name == "workitem" })?.value {
      return WorkItemURL(org: org, project: segments.first, id: id)
    }
    return nil
  }
}
