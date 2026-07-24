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

  @State private var workItemOrg = ""
  @State private var workItemProject = ""
  @State private var loadedDcdp = DcdpConfig()

  @State private var saveError: String?

  private var repoRootURL: URL {
    workspace.clone(forWorktree: worktree)?.rootURL ?? worktree.url
  }

  private var isBranchDirty: Bool {
    baseBranch != (loaded.prjDep ?? "") ||
    workItemID != (loaded.workItemID ?? "") ||
    figmaURL != (loaded.figmaURL ?? "") ||
    slackURL != (loaded.slackChannelURL ?? "")
  }

  private var isRepoDirty: Bool {
    workItemOrg != (loadedDcdp.workItemOrg ?? "") ||
    workItemProject != (loadedDcdp.workItemProject ?? "")
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
        Section {
          Field(title: "Work-item org (WORKITEM_ORG)", text: $workItemOrg,
                prompt: "e.g. your-org-name")
          Field(title: "Work-item project (WORKITEM_PROJECT)", text: $workItemProject,
                prompt: "e.g. Your Project")
        } header: {
          Text("Repository — every branch")
        } footer: {
          Text("Saved to .dcdp/config.toml at the repo root. Overrides the default set in Settings, for repos whose work items live in a different org/project.")
            .font(.caption2)
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
          .disabled(!isBranchDirty && !isRepoDirty)
      }
      .padding(16)
    }
    .frame(width: 460, height: 540)
    .task { load() }
  }

  private func load() {
    loaded = BranchConfig.load(worktree: worktree.url, branch: branch)
    baseBranch = loaded.prjDep ?? ""
    workItemID = loaded.workItemID ?? ""
    figmaURL = loaded.figmaURL ?? ""
    slackURL = loaded.slackChannelURL ?? ""

    loadedDcdp = DcdpConfig.load(worktree: repoRootURL) ?? DcdpConfig()
    workItemOrg = loadedDcdp.workItemOrg ?? ""
    workItemProject = loadedDcdp.workItemProject ?? ""
  }

  private func save() {
    do {
      if isBranchDirty {
        var config = BranchConfig.load(worktree: worktree.url, branch: branch) // keep passthrough lines
        config.prjDep = baseBranch.isEmpty ? nil : baseBranch
        config.workItemID = workItemID.isEmpty ? nil : workItemID
        config.figmaURL = figmaURL.isEmpty ? nil : figmaURL
        config.slackChannelURL = slackURL.isEmpty ? nil : slackURL
        try config.save(worktree: worktree.url, branch: branch)
        Task { await workspace.reloadStatus(for: worktree) } // base branch may have changed
      }
      if isRepoDirty {
        var dcdp = DcdpConfig.load(worktree: repoRootURL) ?? DcdpConfig() // keep passthrough lines
        dcdp.workItemOrg = workItemOrg.isEmpty ? nil : workItemOrg
        dcdp.workItemProject = workItemProject.isEmpty ? nil : workItemProject
        try dcdp.save(worktree: repoRootURL)
      }
      NotificationCenter.default.post(name: .branchConfigChanged, object: nil)
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
