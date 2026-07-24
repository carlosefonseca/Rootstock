import SwiftUI
import SwiftData

@main
struct RootstockApp: App {
  @State private var workspace = WorkspaceModel()
  @State private var terminals = TerminalSessionStore()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(workspace)
        .environment(terminals)
        .frame(minWidth: 820, minHeight: 520)
    }
    .modelContainer(Self.sharedModelContainer)
    .commands {
      CommandGroup(after: .sidebar) {
        Button("Refresh All") { Task { await workspace.refreshAll() } }
          .keyboardShortcut("r", modifiers: .command)
      }
    }

    Settings {
      SettingsView()
        .environment(workspace)
    }
  }

  /// Pinned to an explicit, namespaced path. SwiftData's unqualified default
  /// (`Application Support/default.store`) isn't unique per app and can collide
  /// with any other unsandboxed SwiftData app on the same Mac.
  static let sharedModelContainer: ModelContainer = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let directory = appSupport.appending(path: "Rootstock", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let storeURL = directory.appending(path: "Rootstock.store")
    let configuration = ModelConfiguration(url: storeURL)
    do {
      return try ModelContainer(for: TrackedClone.self, BranchNotes.self, configurations: configuration)
    } catch {
      fatalError("Failed to create Rootstock's SwiftData store at \(storeURL.path): \(error)")
    }
  }()
}
