import Foundation

/// In-memory cache for ADO identity avatars, keyed by the avatar URL. Actor
/// (not `@MainActor`) since it only guards a dictionary and does network I/O —
/// no UI state — and several PR rows can request the same author's avatar
/// concurrently without each doing its own fetch.
actor AvatarCache {
  static let shared = AvatarCache()

  private var cache: [String: Data] = [:]
  private var inFlight: [String: Task<Data?, Never>] = [:]
  private let client = AzureClient()

  func data(org: String, urlString: String) async -> Data? {
    if let cached = cache[urlString] { return cached }
    if let existing = inFlight[urlString] { return await existing.value }

    let task = Task<Data?, Never> { await self.client.imageData(org: org, urlString: urlString) }
    inFlight[urlString] = task
    let result = await task.value
    inFlight[urlString] = nil
    if let result { cache[urlString] = result }
    return result
  }
}
