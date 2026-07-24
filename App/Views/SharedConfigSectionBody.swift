import SwiftUI

/// Reads and writes the tracked `Scripts/branch-sync/<branch>.conf` — shared with
/// teammates on the same branch and with `branch-sync.sh` itself.
struct SharedConfigSectionBody: View {
  @Environment(WorkspaceModel.self) private var workspace
  var worktree: WorktreeInfo
  var branch: String

  @State private var baseBranch = ""
  @State private var workItemID = ""
  @State private var figmaURL = ""
  @State private var slackURL = ""
  @State private var loaded = BranchConfig()
  @State private var saveError: String?

  private var isDirty: Bool {
    baseBranch != (loaded.prjDep ?? "") ||
    workItemID != (loaded.workItemID ?? "") ||
    figmaURL != (loaded.figmaURL ?? "") ||
    slackURL != (loaded.slackChannelURL ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Field(title: "Base branch (PRJ_DEP)", text: $baseBranch, prompt: "develop")
      Field(title: "Work item ID", text: $workItemID, prompt: "205552")

      LinkField(title: "Figma", text: $figmaURL, prompt: "https://figma.com/…") {
        AppOpener.open(figmaURL)
      }
      LinkField(title: "Slack channel", text: $slackURL, prompt: "https://…slack.com/archives/…") {
        openSlack(slackURL)
      }

      if let saveError {
        Label(saveError, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.red)
      }

      HStack {
        Text(BranchConfig.fileName(forBranch: branch))
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
        Spacer()
        Button("Save", systemImage: "square.and.arrow.down") { save() }
          .controlSize(.small)
          .disabled(!isDirty)
      }
    }
    .task { load() }
  }

  private func load() {
    loaded = BranchConfig.load(worktree: worktree.url, branch: branch)
    baseBranch = loaded.prjDep ?? ""
    workItemID = loaded.workItemID ?? ""
    figmaURL = loaded.figmaURL ?? ""
    slackURL = loaded.slackChannelURL ?? ""
  }

  private func save() {
    var config = BranchConfig.load(worktree: worktree.url, branch: branch) // re-read to keep passthrough
    config.prjDep = baseBranch.isEmpty ? nil : baseBranch
    config.workItemID = workItemID.isEmpty ? nil : workItemID
    config.figmaURL = figmaURL.isEmpty ? nil : figmaURL
    config.slackChannelURL = slackURL.isEmpty ? nil : slackURL
    do {
      try config.save(worktree: worktree.url, branch: branch)
      saveError = nil
      loaded = config
      Task { await workspace.reloadStatus(for: worktree) } // base branch may have changed
    } catch {
      saveError = error.localizedDescription
    }
  }

  private func openSlack(_ urlString: String) {
    // Prefer the native Slack app via its archive deep link when possible.
    if let comps = URLComponents(string: urlString),
       let last = comps.path.split(separator: "/").last,
       last.hasPrefix("C") || last.hasPrefix("G") {
      if let deep = URL(string: "slack://channel?id=\(last)") {
        AppOpener.open(deep.absoluteString)
        return
      }
    }
    AppOpener.open(urlString)
  }
}

private struct Field: View {
  var title: String
  @Binding var text: String
  var prompt: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      TextField(title, text: $text, prompt: Text(prompt))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
    }
  }
}

private struct LinkField: View {
  var title: String
  @Binding var text: String
  var prompt: String
  var open: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      HStack {
        TextField(title, text: $text, prompt: Text(prompt))
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
        Button("Open \(title)", systemImage: "arrow.up.right.square") { open() }
          .labelStyle(.iconOnly)
          .disabled(text.isEmpty)
      }
    }
  }
}
