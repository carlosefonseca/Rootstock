import SwiftUI

/// Editor sheet for the tracked `Scripts/branch-sync/<branch>.conf` — shared with
/// teammates on the same branch and with `branch-sync.sh` itself.
struct SharedConfigEditor: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(\.dismiss) private var dismiss
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
    VStack(alignment: .leading, spacing: 0) {
      Text("Shared Config").font(.title2.weight(.semibold)).padding([.horizontal, .top], 20)
      Text(BranchConfig.fileName(forBranch: branch))
        .font(.caption.monospaced()).foregroundStyle(.secondary)
        .padding(.horizontal, 20)

      Form {
        Section {
          Field(title: "Base branch (PRJ_DEP)", text: $baseBranch, prompt: "develop")
          Field(title: "Work item ID", text: $workItemID, prompt: "205552")
        }
        Section("Links") {
          LinkField(title: "Figma", text: $figmaURL, prompt: "https://figma.com/…") {
            AppOpener.open(figmaURL)
          }
          LinkField(title: "Slack channel", text: $slackURL, prompt: "https://…slack.com/archives/…") {
            AppOpener.openSlack(slackURL)
          }
        }
        if let saveError {
          Label(saveError, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Text("Shared with your team via git")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!isDirty)
      }
      .padding(16)
    }
    .frame(width: 460, height: 460)
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
    var config = BranchConfig.load(worktree: worktree.url, branch: branch) // keep passthrough lines
    config.prjDep = baseBranch.isEmpty ? nil : baseBranch
    config.workItemID = workItemID.isEmpty ? nil : workItemID
    config.figmaURL = figmaURL.isEmpty ? nil : figmaURL
    config.slackChannelURL = slackURL.isEmpty ? nil : slackURL
    do {
      try config.save(worktree: worktree.url, branch: branch)
      Task { await workspace.reloadStatus(for: worktree) } // base branch may have changed
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
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
          .labelsHidden()
        Button("Open \(title)", systemImage: "arrow.up.right.square") { open() }
          .labelStyle(.iconOnly)
          .disabled(text.isEmpty)
      }
    }
  }
}
