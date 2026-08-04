import Foundation

enum AzureError: LocalizedError {
  case noCredential(org: String, detail: String? = nil)
  case http(status: Int, message: String)
  case decoding(String)
  case expiredSession(org: String, detail: String? = nil)

  var errorDescription: String? {
    switch self {
    case .noCredential(let org, let detail):
      let base = "No credential for \(org). Add a PAT in Settings, or sign in with `az login`."
      return detail.map { "\(base) (\($0))" } ?? base
    case .http(let status, let message):
      return "Azure DevOps returned \(status)\(message.isEmpty ? "" : ": \(message)")"
    case .decoding(let detail):
      return "Couldn't read the Azure DevOps response (\(detail))."
    case .expiredSession(let org, let detail):
      let base = "Your Azure DevOps session for \(org) looks expired — sign in again with `az login`, or check the PAT in Settings."
      return detail.map { "\(base) (\($0))" } ?? base
    }
  }
}

/// Pulls whatever's diagnostic out of an AAD/ADO sign-in or block page — the
/// `AADSTS######` code when there is one (the specific, actionable reason:
/// conditional access, consent required, wrong tenant, ...), else the page
/// `<title>`, else nothing worth showing.
private func diagnosticSnippet(from data: Data) -> String? {
  guard let text = String(data: data, encoding: .utf8) else { return nil }
  if let range = text.range(of: #"AADSTS\d+[^"'<]*"#, options: .regularExpression) {
    return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  if let range = text.range(of: #"<title[^>]*>([^<]*)</title>"#, options: [.regularExpression, .caseInsensitive]),
     let titleRange = text.range(of: #"(?<=>)[^<]*(?=</title>)"#, options: [.regularExpression, .caseInsensitive], range: range) {
    let title = text[titleRange].trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }
  return nil
}

private extension UInt8 {
  var isWhitespaceASCII: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}

/// A small `URLSession` REST client for Azure DevOps at `api-version=7.1`. No SDK
/// exists for Swift and the surface area (PRs, pipelines, work items, connection
/// data) is tiny, so this is hand-rolled.
struct AzureClient {
  /// GA across Azure DevOps Services and Server 2022. Some resources are only
  /// available under a preview version — those calls pass an explicit
  /// `apiVersion` (e.g. "7.0-preview.1").
  var apiVersion = "7.0"
  private let session = URLSession(configuration: .ephemeral)

  /// GETs `path` under `org` (org is always the URL base here; `path` includes the
  /// project segment when needed). `query` is merged with the api-version.
  func get<T: Decodable>(_ type: T.Type, org: String, path: String,
                         query: [String: String] = [:], apiVersion: String? = nil) async throws -> T {
    try await send(type, method: "GET", org: org, path: path, query: query, apiVersion: apiVersion)
  }

  /// POSTs `body` as JSON to `path` and decodes the created resource — the write
  /// counterpart to `get`, used for queueing builds.
  func post<T: Decodable>(_ type: T.Type, org: String, path: String, body: [String: Any],
                          query: [String: String] = [:], apiVersion: String? = nil) async throws -> T {
    let data = try JSONSerialization.data(withJSONObject: body)
    return try await send(type, method: "POST", org: org, path: path, query: query,
                          apiVersion: apiVersion, body: data)
  }

  /// PATCHes `path` with no body — how ADO models "requeue this policy
  /// evaluation".
  @discardableResult
  func patch<T: Decodable>(_ type: T.Type, org: String, path: String,
                           query: [String: String] = [:], apiVersion: String? = nil) async throws -> T {
    try await send(type, method: "PATCH", org: org, path: path, query: query, apiVersion: apiVersion,
                   body: Data("{}".utf8))
  }

  private func send<T: Decodable>(_ type: T.Type, method: String, org: String, path: String,
                                  query: [String: String], apiVersion: String?,
                                  body: Data? = nil) async throws -> T {
    guard let token = await AzureAuth.shared.token(forOrg: org) else {
      throw AzureError.noCredential(org: org, detail: await AzureAuth.shared.lastAzFailure)
    }
    var comps = URLComponents(string: "https://dev.azure.com/\(org)/\(path)")!
    var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    items.append(URLQueryItem(name: "api-version", value: apiVersion ?? self.apiVersion))
    comps.queryItems = items

    var request = URLRequest(url: comps.url!)
    request.httpMethod = method
    request.setValue(token.authorizationHeader, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      // ADO often returns an error object with a "message" field.
      var message = ""
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let m = json["message"] as? String { message = m }
      throw AzureError.http(status: status, message: message)
    }
    // An expired/invalid AAD session can get a 200 OK sign-in page back
    // instead of JSON (the failure that actually prompted this check) rather
    // than a clean 401 — surface that plainly instead of a raw JSON parsing
    // error that gives no hint of what actually went wrong.
    if let firstByte = data.first(where: { !$0.isWhitespaceASCII }), firstByte == UInt8(ascii: "<") {
      throw AzureError.expiredSession(org: org, detail: diagnosticSnippet(from: data))
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw AzureError.decoding(String(describing: error))
    }
  }

  /// The signed-in identity for `org`, from the org's `connectionData`. The `id`
  /// on the result is the same GUID ADO uses in `ADOReviewer.id` and
  /// `ADOComment.author.id`, so it's what callers compare against to answer
  /// "is this PR/comment/vote mine?".
  func currentIdentity(org: String) async throws -> ADOIdentity {
    struct ConnectionData: Decodable { var authenticatedUser: ADOIdentity? }
    // connectionData is a preview-only resource, so it needs an explicit preview version.
    let data = try await get(ConnectionData.self, org: org, path: "_apis/connectionData",
                             apiVersion: "7.0-preview.1")
    guard let identity = data.authenticatedUser else {
      throw AzureError.decoding("connectionData had no authenticatedUser")
    }
    return identity
  }

  /// Fetches raw bytes from an already-authenticated ADO URL, e.g. an
  /// `ADOIdentity.imageUrl` avatar — those aren't public images and need the
  /// same bearer/PAT auth as any other ADO API call.
  func imageData(org: String, urlString: String) async -> Data? {
    guard let token = await AzureAuth.shared.token(forOrg: org), let url = URL(string: urlString) else {
      return nil
    }
    var request = URLRequest(url: url)
    request.setValue(token.authorizationHeader, forHTTPHeaderField: "Authorization")
    guard let (data, response) = try? await session.data(for: request),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else { return nil }
    return data
  }

  /// `connectionData` is the lightweight endpoint used to confirm auth works.
  func testConnection(org: String) async -> Result<String, AzureError> {
    do {
      let identity = try await currentIdentity(org: org)
      return .success(identity.providerDisplayName ?? "connected")
    } catch let error as AzureError {
      return .failure(error)
    } catch {
      return .failure(.decoding(error.localizedDescription))
    }
  }
}
