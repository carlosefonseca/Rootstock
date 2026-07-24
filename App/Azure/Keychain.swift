import Foundation
import Security

/// Minimal wrapper over Keychain generic passwords. Used only for Azure DevOps
/// PATs — the one credential the plan says must never become a repo file.
enum Keychain {
  private static let service = "Rootstock.AzureDevOps"

  // In-memory cache so the PAT is read from the keychain at most once per launch.
  // Without this, every Azure DevOps request re-reads the item and macOS re-prompts
  // for keychain access. `nil` means "known to be absent" (avoids repeat lookups).
  private static let lock = NSLock()
  private static var cache: [String: String?] = [:]

  static func setPAT(_ pat: String, org: String) {
    delete(org: org)
    guard !pat.isEmpty else { return }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: org,
      kSecValueData as String: Data(pat.utf8),
      // Only accessible while unlocked, and never migrated to other devices.
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    SecItemAdd(query as CFDictionary, nil)
    lock.lock(); cache[org] = pat; lock.unlock()
  }

  static func pat(org: String) -> String? {
    lock.lock()
    if let cached = cache[org] { lock.unlock(); return cached }
    lock.unlock()

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: org,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    let value = (status == errSecSuccess && item is Data)
      ? String(decoding: item as! Data, as: UTF8.self) : nil

    lock.lock(); cache[org] = value; lock.unlock()
    return value
  }

  static func delete(org: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: org,
    ]
    SecItemDelete(query as CFDictionary)
    lock.lock(); cache.removeValue(forKey: org); lock.unlock()
  }
}
