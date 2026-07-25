import Foundation

/// Generic `{ count, value: [...] }` list wrapper ADO returns for collections.
struct ADOList<T: Decodable>: Decodable {
  var value: [T]
}

/// A person, as ADO represents them across different endpoints: the `IdentityRef`
/// shape (reviewers, comment authors) sets `displayName`; the `connectionData`
/// authenticated-user shape sets `providerDisplayName` instead. `id` is the
/// stable GUID comparable across both shapes within the same org.
struct ADOIdentity: Decodable, Hashable {
  var id: String
  var displayName: String?
  var uniqueName: String?
  var providerDisplayName: String?

  var name: String { displayName ?? providerDisplayName ?? uniqueName ?? id }
}

// MARK: Pull requests

struct ADOPullRequest: Decodable, Identifiable {
  var pullRequestId: Int
  var title: String
  var description: String?
  var status: String            // active / completed / abandoned
  var isDraft: Bool?
  var mergeStatus: String?      // succeeded / conflicts / queued / …
  var sourceRefName: String?
  var targetRefName: String?
  var reviewers: [ADOReviewer]?
  var createdBy: ADOIdentity?

  var id: Int { pullRequestId }
  var targetBranch: String? { targetRefName?.replacingOccurrences(of: "refs/heads/", with: "") }
}

struct ADOReviewer: Decodable, Identifiable {
  var id: String
  var displayName: String
  var vote: Int                 // 10 approved, 5 approved w/ suggestions, 0 none, -5 waiting, -10 rejected
  var isRequired: Bool?

  enum Vote: String {
    case approved, approvedWithSuggestions, noVote, waiting, rejected
  }

  var voteKind: Vote {
    switch vote {
    case 10: return .approved
    case 5: return .approvedWithSuggestions
    case -5: return .waiting
    case -10: return .rejected
    default: return .noVote
    }
  }
}

struct ADOThread: Decodable {
  var id: Int = -1              // default keeps decoding additive if a payload ever omits it
  var status: String?           // active / fixed / closed / wontFix / pending / byDesign
  var isDeleted: Bool?
  var comments: [ADOComment]?

  var isUnresolved: Bool {
    guard isDeleted != true else { return false }
    // A thread with a status of "active" or "pending" counts as unresolved.
    return status == "active" || status == "pending"
  }
}

struct ADOComment: Decodable, Identifiable {
  var id: Int
  var parentCommentId: Int?
  var author: ADOIdentity?
  var content: String?
  var commentType: String?      // text / system
}

// MARK: Build / pipeline

struct ADOBuild: Decodable, Identifiable {
  var id: Int
  var buildNumber: String?
  var status: String?           // notStarted / inProgress / completed
  var result: String?           // succeeded / partiallySucceeded / failed / canceled
  var _links: Links?

  struct Links: Decodable {
    var web: Href?
    struct Href: Decodable { var href: String? }
  }
  var webURL: String? { _links?.web?.href }
}

/// A build/policy check attached to a specific pull request (distinct from
/// `ADOBuild`, which is a branch-scoped build lookup).
struct ADOStatus: Decodable {
  var id: Int?
  var state: String?            // notApplicable / error / failed / notSet / pending / succeeded
  var description: String?
  var targetUrl: String?
  var context: Context?

  struct Context: Decodable {
    var name: String?
    var genre: String?
  }
}

// MARK: Work items

struct ADOWorkItem: Decodable, Identifiable {
  var id: Int
  var fields: [String: ADOAnyValue]?

  var title: String? { fields?["System.Title"]?.string }
  var state: String? { fields?["System.State"]?.string }
  var type: String? { fields?["System.WorkItemType"]?.string }
}

/// Decodes ADO field values that may be strings, numbers, or objects — we only
/// need their string form here.
struct ADOAnyValue: Decodable {
  var string: String?

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let s = try? container.decode(String.self) { string = s }
    else if let i = try? container.decode(Int.self) { string = String(i) }
    else if let d = try? container.decode(Double.self) { string = String(d) }
    else { string = nil }
  }
}
