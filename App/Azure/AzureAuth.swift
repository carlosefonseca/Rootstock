import Foundation

/// A resolved credential for talking to an Azure DevOps org.
enum AzureToken {
  case pat(String)      // Personal access token → Basic auth
  case bearer(String)   // AAD access token from `az` → Bearer auth

  var authorizationHeader: String {
    switch self {
    case .pat(let pat):
      // ADO Basic auth: empty username, PAT as password.
      let encoded = Data(":\(pat)".utf8).base64EncodedString()
      return "Basic \(encoded)"
    case .bearer(let token):
      return "Bearer \(token)"
    }
  }

  var kind: String {
    switch self {
    case .pat: return "PAT"
    case .bearer: return "az (AAD)"
    }
  }
}

/// Resolves an `AzureToken` for an org, in the order the plan specifies:
/// Keychain PAT → `az account get-access-token` → none. AAD tokens are cached in
/// memory until shortly before they expire.
actor AzureAuth {
  static let shared = AzureAuth()

  // ADO's AAD resource id (Azure DevOps).
  private let resource = "499b84ac-1321-427f-aa17-267ca6975798"

  private struct CachedToken {
    var token: String
    var expiresAt: Date
  }
  private var azCache: CachedToken?

  /// The credential to use for `org`, honouring the per-org auth mode. In `.az`
  /// mode the keychain is never read, so no keychain prompt appears.
  func token(forOrg org: String) async -> AzureToken? {
    switch AzureSettingsStore.authMode(org: org) {
    case .az:
      return await azToken().map(AzureToken.bearer)
    case .pat:
      if let pat = Keychain.pat(org: org), !pat.isEmpty { return .pat(pat) }
      return nil
    case .auto:
      if let pat = Keychain.pat(org: org), !pat.isEmpty { return .pat(pat) }
      return await azToken().map(AzureToken.bearer)
    }
  }

  /// True when the machine has an authenticated `az` session we can reuse.
  func hasAzSession() async -> Bool {
    let result = await ShellRunner.run("az account show -o json")
    return result.succeeded
  }

  private func azToken() async -> String? {
    if let cached = azCache, cached.expiresAt > Date().addingTimeInterval(60) {
      return cached.token
    }
    let result = await ShellRunner.run(
      "az account get-access-token --resource \(resource) -o json")
    guard result.succeeded,
          let data = result.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = json["accessToken"] as? String else { return nil }

    var expires = Date().addingTimeInterval(3000)
    if let expiresOn = json["expires_on"] as? Double {
      expires = Date(timeIntervalSince1970: expiresOn)
    } else if let expiresOn = json["expires_on"] as? String, let secs = Double(expiresOn) {
      expires = Date(timeIntervalSince1970: secs)
    }
    azCache = CachedToken(token: token, expiresAt: expires)
    return token
  }
}
