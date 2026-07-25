import Foundation

enum AzureError: LocalizedError {
  case noCredential(org: String)
  case http(status: Int, message: String)
  case decoding(String)

  var errorDescription: String? {
    switch self {
    case .noCredential(let org):
      return "No credential for \(org). Add a PAT in Settings, or sign in with `az login`."
    case .http(let status, let message):
      return "Azure DevOps returned \(status)\(message.isEmpty ? "" : ": \(message)")"
    case .decoding(let detail):
      return "Couldn't read the Azure DevOps response (\(detail))."
    }
  }
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
    guard let token = await AzureAuth.shared.token(forOrg: org) else {
      throw AzureError.noCredential(org: org)
    }
    var comps = URLComponents(string: "https://dev.azure.com/\(org)/\(path)")!
    var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    items.append(URLQueryItem(name: "api-version", value: apiVersion ?? self.apiVersion))
    comps.queryItems = items

    var request = URLRequest(url: comps.url!)
    request.setValue(token.authorizationHeader, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      // ADO often returns an error object with a "message" field.
      var message = ""
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let m = json["message"] as? String { message = m }
      throw AzureError.http(status: status, message: message)
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
