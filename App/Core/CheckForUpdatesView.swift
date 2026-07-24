import Sparkle
import SwiftUI

/// The standard SwiftUI recipe for a "Check for Updates…" menu item: Sparkle's
/// `SPUUpdater.canCheckForUpdates` is KVO-observable, not `@Observable`-native,
/// so a small ObservableObject bridges it into SwiftUI's update cycle.
@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
  @Published var canCheckForUpdates = false
  private var observation: NSKeyValueObservation?

  init(updater: SPUUpdater) {
    observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
      Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
    }
  }
}

struct CheckForUpdatesView: View {
  @StateObject private var viewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  init(updater: SPUUpdater) {
    self.updater = updater
    _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
  }

  var body: some View {
    Button("Check for Updates…") { updater.checkForUpdates() }
      .disabled(!viewModel.canCheckForUpdates)
  }
}
