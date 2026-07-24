import Foundation
import Security

/// Minimal wrapper over Keychain generic passwords. Used only for Azure DevOps
/// PATs — the one credential the plan says must never become a repo file.
enum Keychain {
  private static let service = "Rootstock.AzureDevOps"

  static func setPAT(_ pat: String, org: String) {
    delete(org: org)
    guard !pat.isEmpty else { return }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: org,
      kSecValueData as String: Data(pat.utf8),
    ]
    SecItemAdd(query as CFDictionary, nil)
  }

  static func pat(org: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: org,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  static func delete(org: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: org,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
