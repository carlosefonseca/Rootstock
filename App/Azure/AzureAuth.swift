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

  /// Why the last `azToken()` call returned nil — surfaced in
  /// `AzureError.noCredential` so a failure past `az account show` (wrong
  /// tenant, `az` not resolvable from the app's login shell, unexpected CLI
  /// output) is diagnosable from the error message alone instead of needing
  /// someone to reproduce it with terminal access to the affected machine.
  private(set) var lastAzFailure: String?

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

  /// Drops the cached AAD token so the next request has to ask `az` for a new
  /// one. Worth doing whenever a request comes back rejected: an access token
  /// that hasn't reached its stated expiry can still stop being accepted (a
  /// conditional-access re-evaluation, a tenant policy change), and without
  /// this the app keeps presenting the dead one for the rest of its lifetime —
  /// which is why signing in again in a terminal used to appear to do nothing.
  func invalidateAzToken() {
    azCache = nil
  }

  /// Asks `az` for a fresh token right now, ignoring the cache. This is the
  /// cheap repair: `az account get-access-token` renews silently through MSAL
  /// as long as the sign-in itself is still good, so it fixes a stale token
  /// without any interaction. It's only when *that* fails that the sign-in has
  /// genuinely lapsed and `az login --allow-no-subscriptions` is unavoidable.
  @discardableResult
  func refreshAzToken() async -> Bool {
    azCache = nil
    return await azToken() != nil
  }

  private func azToken() async -> String? {
    if let cached = azCache, cached.expiresAt > Date().addingTimeInterval(60) {
      return cached.token
    }
    let result = await ShellRunner.run(
      "az account get-access-token --resource \(resource) -o json")
    guard result.succeeded else {
      let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      lastAzFailure = stderr.isEmpty ? "`az account get-access-token` exited \(result.exitCode)" : stderr
      return nil
    }
    guard let data = result.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = json["accessToken"] as? String else {
      let preview = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
      lastAzFailure = "`az account get-access-token` returned unexpected output: \(preview)"
      return nil
    }

    var expires = Date().addingTimeInterval(3000)
    if let expiresOn = json["expires_on"] as? Double {
      expires = Date(timeIntervalSince1970: expiresOn)
    } else if let expiresOn = json["expires_on"] as? String, let secs = Double(expiresOn) {
      expires = Date(timeIntervalSince1970: secs)
    }
    azCache = CachedToken(token: token, expiresAt: expires)
    lastAzFailure = nil
    return token
  }
}
