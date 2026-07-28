import SwiftUI

/// Editor sheet for the tracked `Scripts/branch-sync/<branch>.conf` — shared with
/// teammates on the same branch and with `branch-sync.sh` itself.
struct SharedConfigEditor: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(\.dismiss) private var dismiss
  var worktree: WorktreeInfo
  var branch: String

  @State private var baseBranch = ""
  @State private var workItemURLs: [String] = []
  @State private var additionalPRURLs: [String] = []
  @State private var figmaURL = ""
  @State private var slackURL = ""
  @State private var loaded = BranchConfig()

  @State private var saveError: String?

  private var isBranchDirty: Bool {
    baseBranch != (loaded.prjDep ?? "") ||
    workItemURLs.filter({ !$0.isEmpty }) != loaded.workItemURLs ||
    additionalPRURLs.filter({ !$0.isEmpty }) != loaded.additionalPRURLs ||
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
        Section("Branch — \(branch)") {
          Field(title: "Base branch (PRJ_DEP)", text: $baseBranch, prompt: "develop")
        }
        Section {
          WorkItemURLListEditor(urls: $workItemURLs)
        } header: {
          Text("Work items")
        } footer: {
          Text("Paste full Azure DevOps work item URLs — org and project come from the link itself.")
            .font(.caption2)
        }
        Section {
          PullRequestURLListEditor(urls: $additionalPRURLs)
        } header: {
          Text("Additional pull requests")
        } footer: {
          Text("For work split across several PRs — the one matching this branch's name is already shown automatically.")
            .font(.caption2)
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
          .disabled(!isBranchDirty)
      }
      .padding(16)
    }
    .frame(width: 640, height: 680)
    .task { load() }
  }

  private func load() {
    loaded = BranchConfig.load(worktree: worktree.url, branch: branch)
    baseBranch = loaded.prjDep ?? ""
    workItemURLs = loaded.workItemURLs
    additionalPRURLs = loaded.additionalPRURLs
    figmaURL = loaded.figmaURL ?? ""
    slackURL = loaded.slackChannelURL ?? ""
  }

  private func save() {
    do {
      var config = BranchConfig.load(worktree: worktree.url, branch: branch) // keep passthrough lines
      config.prjDep = baseBranch.isEmpty ? nil : baseBranch
      config.workItemURLs = workItemURLs.filter { !$0.isEmpty }
      config.additionalPRURLs = additionalPRURLs.filter { !$0.isEmpty }
      config.figmaURL = figmaURL.isEmpty ? nil : figmaURL
      config.slackChannelURL = slackURL.isEmpty ? nil : slackURL
      try config.save(worktree: worktree.url, branch: branch)
      Task { await workspace.reloadStatus(for: worktree) } // base branch may have changed
      NotificationCenter.default.post(name: .branchConfigChanged, object: nil)
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
  }
}

private struct WorkItemURLListEditor: View {
  @Binding var urls: [String]
  @FocusState private var focusedIndex: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(urls.indices, id: \.self) { index in
        HStack {
          TextField("Work item URL", text: $urls[index],
                     prompt: Text("https://dev.azure.com/org/project/_workitems/edit/12345"))
            .labelsHidden()
            .focused($focusedIndex, equals: index)
          Button("Remove", systemImage: "minus.circle") { urls.remove(at: index) }
            .labelStyle(.iconOnly).foregroundStyle(.secondary)
        }
      }
      Button("Add Work Item", systemImage: "plus.circle") {
        urls.append("")
        focusedIndex = urls.count - 1
      }
      .labelStyle(.titleAndIcon)
    }
  }
}

private struct PullRequestURLListEditor: View {
  @Binding var urls: [String]
  @FocusState private var focusedIndex: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(urls.indices, id: \.self) { index in
        HStack {
          TextField("Pull request URL", text: $urls[index],
                     prompt: Text("https://dev.azure.com/org/project/_git/repo/pullrequest/12345"))
            .labelsHidden()
            .focused($focusedIndex, equals: index)
          Button("Remove", systemImage: "minus.circle") { urls.remove(at: index) }
            .labelStyle(.iconOnly).foregroundStyle(.secondary)
        }
      }
      Button("Add Pull Request", systemImage: "plus.circle") {
        urls.append("")
        focusedIndex = urls.count - 1
      }
      .labelStyle(.titleAndIcon)
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
