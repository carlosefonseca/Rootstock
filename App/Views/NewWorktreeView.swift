import SwiftUI
import AppKit

/// Creates a new worktree and writes its shared config in one step. The Azure
/// DevOps work-item *lookup* (search / auto-fill) is a later phase; for now the
/// id, title, and links are entered directly, and the worktree + conf are created
/// exactly as the plan's confirm step describes.
struct NewWorktreeView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(\.dismiss) private var dismiss

  @State private var selectedCloneID: String?
  @State private var workItemID = ""
  @State private var title = ""
  @State private var type: WorkItemType = .feature
  @State private var branchEdited = false
  @State private var branch = ""
  @State private var baseBranch = "develop"
  @State private var figmaURL = ""
  @State private var slackURL = ""
  @State private var parentDir: URL?
  @State private var creating = false
  @State private var error: String?
  @State private var fetching = false
  @State private var fetchError: String?

  enum WorkItemType: String, CaseIterable, Identifiable {
    case feature = "feature", bugfix = "bugfix", chore = "chore"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
  }

  private var selectedClone: TrackedClone? {
    workspace.clones.first { $0.commonDir == selectedCloneID }
  }

  private var derivedBranch: String {
    let slug = title
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let idPart = workItemID.isEmpty ? "" : "\(workItemID)-"
    return "\(type.rawValue)/\(idPart)\(slug)"
  }

  private var effectiveBranch: String { branchEdited ? branch : derivedBranch }

  private var targetPath: URL? {
    guard let parent = parentDir ?? selectedClone?.rootURL.deletingLastPathComponent() else { return nil }
    let folder = effectiveBranch.replacingOccurrences(of: "/", with: "-")
    return parent.appending(path: folder)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("New Worktree").font(.title2.weight(.semibold)).padding([.horizontal, .top], 20)

      Form {
        Section("Clone") {
          Picker("Clone", selection: $selectedCloneID) {
            Text("Choose…").tag(String?.none)
            ForEach(workspace.clones) { clone in
              Text(clone.displayName).tag(String?.some(clone.commonDir))
            }
          }
        }

        Section("Work item") {
          HStack {
            TextField("Work item ID", text: $workItemID, prompt: Text("205552"))
            Button("Fetch", systemImage: "arrow.down.circle") { fetchWorkItem() }
              .labelStyle(.iconOnly)
              .disabled(workItemID.isEmpty || selectedClone == nil || fetching)
            if fetching { ProgressView().controlSize(.small) }
          }
          TextField("Title", text: $title, prompt: Text("Payment state refactor"))
          Picker("Type", selection: $type) {
            ForEach(WorkItemType.allCases) { Text($0.label).tag($0) }
          }
          if let fetchError {
            Label(fetchError, systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(.orange)
          }
        }

        Section("Branch") {
          TextField("Branch", text: Binding(
            get: { effectiveBranch },
            set: { branch = $0; branchEdited = true }))
            .font(.body.monospaced())
          TextField("Base branch", text: $baseBranch, prompt: Text("develop"))
          LabeledContent("Location") {
            HStack {
              Text(targetPath?.path ?? "—")
                .font(.caption.monospaced())
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
              Button("Choose…") { chooseParent() }.controlSize(.small)
            }
          }
        }

        Section("Shared config") {
          TextField("Figma URL", text: $figmaURL, prompt: Text("optional"))
          TextField("Slack channel URL", text: $slackURL, prompt: Text("optional"))
        }

        if let error {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Create Worktree") { create() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate || creating)
      }
      .padding(16)
    }
    .frame(width: 520, height: 620)
    .onAppear { if selectedCloneID == nil { selectedCloneID = workspace.clones.first?.commonDir } }
  }

  private var canCreate: Bool {
    selectedClone != nil && !effectiveBranch.hasSuffix("/") && !baseBranch.isEmpty && targetPath != nil
  }

  /// Looks the work item up in Azure DevOps and pre-fills title + type.
  private func fetchWorkItem() {
    guard let clone = selectedClone else { return }
    let org = DcdpConfig.load(worktree: clone.rootURL)?.workItemOrg
      ?? AzureSettingsStore.defaultWorkItemOrg
      ?? AzureRemote.parse(clone.remoteURL)?.org
    guard let org else {
      fetchError = "No Azure DevOps organization for this clone."
      return
    }
    fetching = true
    fetchError = nil
    let id = workItemID
    Task {
      do {
        let item = try await AzureService().workItem(org: org, id: id)
        if let fetchedTitle = item.title { title = fetchedTitle }
        if let fetchedType = item.type { type = mapType(fetchedType) }
      } catch {
        fetchError = error.localizedDescription
      }
      fetching = false
    }
  }

  private func mapType(_ adoType: String) -> WorkItemType {
    switch adoType.lowercased() {
    case "user story", "feature": return .feature
    case "bug": return .bugfix
    default: return .chore
    }
  }

  private func chooseParent() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Choose"
    if panel.runModal() == .OK { parentDir = panel.url }
  }

  private func create() {
    guard let clone = selectedClone, let path = targetPath else { return }
    creating = true
    error = nil
    let branchName = effectiveBranch
    Task {
      let quotedPath = "'\(path.path)'"
      let command = "git worktree add \(quotedPath) -b '\(branchName)' 'origin/\(baseBranch)'"
      let result = await ShellRunner.run(command, in: clone.rootURL)
      if !result.succeeded {
        error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = false
        return
      }

      // Write the initial shared conf, matching branch-sync's own defaults.
      var config = BranchConfig()
      config.prjDep = baseBranch
      config.dsBranch = "na"
      config.dsDep = "na"
      config.workItemID = workItemID.isEmpty ? nil : workItemID
      config.figmaURL = figmaURL.isEmpty ? nil : figmaURL
      config.slackChannelURL = slackURL.isEmpty ? nil : slackURL
      try? config.save(worktree: path, branch: branchName)

      await workspace.refreshClone(commonDir: clone.commonDir, rootURL: clone.rootURL)
      workspace.selectedPath = path.path
      creating = false
      dismiss()
    }
  }
}
