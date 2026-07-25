import Sparkle
import SwiftUI
import SwiftData

@main
struct RootstockApp: App {
  @State private var workspace = WorkspaceModel()
  @State private var tabsStore = WorktreeTabsStore()
  @State private var linksStore = WorktreeLinksStore()
  @State private var prWorkModel = CrossRepoPRWorkModel()
  @Environment(\.openWindow) private var openWindow
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(workspace)
        .environment(tabsStore)
        .environment(linksStore)
        .environment(prWorkModel)
        .frame(minWidth: 820, minHeight: 520)
    }
    .modelContainer(Self.sharedModelContainer)
    .commands {
      CommandGroup(after: .appInfo) {
        CheckForUpdatesView(updater: updaterController.updater)
      }
      CommandGroup(after: .sidebar) {
        Button("Refresh All") {
          Task {
            await workspace.refreshAll()
            prWorkModel.refresh(clones: workspace.clones)
          }
        }
        .keyboardShortcut("r", modifiers: .command)
        Button("Pull Request Work") { openWindow(id: "pr-work") }
          .keyboardShortcut("p", modifiers: [.command, .shift])
        Divider()
        Button("Next Worktree") { workspace.selectAdjacentWorktree(offset: 1) }
          .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        Button("Previous Worktree") { workspace.selectAdjacentWorktree(offset: -1) }
          .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
      }
    }

    Settings {
      SettingsView()
        .environment(workspace)
    }

    Window("Pull Request Work", id: "pr-work") {
      MyPRWorkView()
        .environment(workspace)
        .environment(tabsStore)
        .environment(prWorkModel)
    }
    .defaultSize(width: 640, height: 440)
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
