import SwiftUI
import AppKit

/// Creates a worktree — either for a brand-new branch or an existing one — and
/// writes its shared config in one step, pre-filling the work item id.
struct NewWorktreeView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(\.dismiss) private var dismiss

  enum Source: String, CaseIterable, Identifiable {
    case newBranch, existingBranch
    var id: String { rawValue }
    var label: String { self == .newBranch ? "New branch" : "Existing branch" }
  }

  enum WorkItemType: String, CaseIterable, Identifiable {
    case feature = "feature", bugfix = "bugfix", chore = "chore"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
  }

  @State private var source: Source = .newBranch
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
  @State private var fetchedTitle: String?

  // Existing-branch state.
  @State private var existingBranch = ""
  @State private var localBranches: [String] = []
  @State private var remoteBranches: [String] = []

  private var selectedClone: TrackedClone? {
    workspace.clones.first { $0.commonDir == selectedCloneID }
  }

  private var isRemoteSelection: Bool { existingBranch.hasPrefix("origin/") }
  private var existingLocalName: String {
    isRemoteSelection ? String(existingBranch.dropFirst("origin/".count)) : existingBranch
  }

  private var derivedBranch: String {
    let slug = title
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let idPart = workItemID.isEmpty ? "" : "\(workItemID)-"
    return "\(type.rawValue)/\(idPart)\(slug)"
  }

  private var effectiveBranch: String {
    source == .newBranch ? (branchEdited ? branch : derivedBranch) : existingLocalName
  }

  private var targetPath: URL? {
    guard let parent = parentDir ?? selectedClone?.rootURL.deletingLastPathComponent(),
          !effectiveBranch.isEmpty else { return nil }
    let folder = effectiveBranch.replacingOccurrences(of: "/", with: "-")
    return parent.appending(path: folder)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("New Worktree").font(.title2.weight(.semibold)).padding([.horizontal, .top], 20)

      Form {
        Section {
          Picker("Source", selection: $source) {
            ForEach(Source.allCases) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
          Picker("Clone", selection: $selectedCloneID) {
            Text("Choose…").tag(String?.none)
            ForEach(workspace.clones) { clone in
              Text(clone.displayName).tag(String?.some(clone.commonDir))
            }
          }
        }

        if source == .existingBranch {
          existingBranchSection
        } else {
          newBranchSection
        }

        Section("Work item") {
          HStack {
            TextField("Work item ID", text: $workItemID, prompt: Text("205552"))
            Button("Fetch", systemImage: "arrow.down.circle") { fetchWorkItem() }
              .labelStyle(.iconOnly)
              .disabled(workItemID.isEmpty || selectedClone == nil || fetching)
            if fetching { ProgressView().controlSize(.small) }
          }
          if source == .newBranch {
            TextField("Title", text: $title, prompt: Text("Payment state refactor"))
            Picker("Type", selection: $type) {
              ForEach(WorkItemType.allCases) { Text($0.label).tag($0) }
            }
          } else if let fetchedTitle {
            Text(fetchedTitle).font(.caption).foregroundStyle(.secondary)
          }
          if let fetchError {
            Label(fetchError, systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(.orange)
          }
        }

        Section("Shared config") {
          TextField("Base branch (PRJ_DEP)", text: $baseBranch, prompt: Text("develop"))
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
    .frame(width: 520, height: 640)
    .onAppear { if selectedCloneID == nil { selectedCloneID = workspace.clones.first?.commonDir } }
    .onChange(of: selectedCloneID) { reloadBranches() }
    .onChange(of: source) { reloadBranches() }
    .onChange(of: existingBranch) { autofillWorkItemFromBranch() }
  }

  @ViewBuilder private var newBranchSection: some View {
    Section("Branch") {
      TextField("Branch", text: Binding(
        get: { effectiveBranch },
        set: { branch = $0; branchEdited = true }))
        .font(.body.monospaced())
      TextField("Base branch", text: $baseBranch, prompt: Text("develop"))
      locationRow
    }
  }

  @ViewBuilder private var existingBranchSection: some View {
    Section("Branch") {
      Picker("Branch", selection: $existingBranch) {
        Text("Choose…").tag("")
        if !localBranches.isEmpty {
          ForEach(localBranches, id: \.self) { Text($0).tag($0) }
        }
        if !remoteBranches.isEmpty {
          Divider()
          ForEach(remoteBranches, id: \.self) { Text($0).tag($0) }
        }
      }
      if isRemoteSelection {
        Text("Creates local branch \(existingLocalName) tracking \(existingBranch).")
          .font(.caption).foregroundStyle(.secondary)
      }
      locationRow
    }
  }

  private var locationRow: some View {
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

  private var canCreate: Bool {
    guard selectedClone != nil, targetPath != nil, !creating else { return false }
    switch source {
    case .newBranch: return !effectiveBranch.hasSuffix("/") && !effectiveBranch.isEmpty && !baseBranch.isEmpty
    case .existingBranch: return !existingBranch.isEmpty
    }
  }

  private func reloadBranches() {
    fetchedTitle = nil
    guard source == .existingBranch, let clone = selectedClone else { return }
    Task {
      let result = await Git.branches(in: clone.rootURL)
      localBranches = result.local
      // Hide remotes that already have a local branch of the same name.
      let localSet = Set(result.local)
      remoteBranches = result.remote.filter { !localSet.contains(String($0.dropFirst("origin/".count))) }
    }
  }

  /// Pre-fill the work item id from a leading numeric token in the branch name.
  private func autofillWorkItemFromBranch() {
    guard workItemID.isEmpty, !existingLocalName.isEmpty else { return }
    if let match = existingLocalName.range(of: #"\d{4,7}"#, options: .regularExpression) {
      workItemID = String(existingLocalName[match])
    }
  }

  /// Looks the work item up in Azure DevOps and pre-fills title + type.
  private func fetchWorkItem() {
    guard let clone = selectedClone else { return }
    let dcdp = DcdpConfig.load(worktree: clone.rootURL)
    let org = dcdp?.workItemOrg
      ?? AzureSettingsStore.defaultWorkItemOrg
      ?? AzureRemote.parse(clone.remoteURL)?.org
    let project = dcdp?.workItemProject ?? AzureSettingsStore.defaultWorkItemProject
    guard let org else {
      fetchError = "No Azure DevOps organization for this clone."
      return
    }
    fetching = true
    fetchError = nil
    let id = workItemID
    Task {
      do {
        let item = try await AzureService().workItem(org: org, project: project, id: id)
        fetchedTitle = item.title
        if source == .newBranch {
          if let fetchedTitle = item.title { title = fetchedTitle }
          if let fetchedType = item.type { type = mapType(fetchedType) }
        }
      } catch {
        let scope = project.map { "\(org)/\($0)" } ?? org
        fetchError = "\(error.localizedDescription) (queried \(scope))"
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
    let command = gitCommand(path: path)
    Task {
      let result = await ShellRunner.run(command, in: clone.rootURL)
      if !result.succeeded {
        error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = false
        return
      }

      // Write the initial shared conf, carrying forward anything already present.
      var config = BranchConfig.load(worktree: path, branch: branchName)
      if !baseBranch.isEmpty { config.prjDep = baseBranch }
      config.dsBranch = config.dsBranch ?? "na"
      config.dsDep = config.dsDep ?? "na"
      if !workItemID.isEmpty { config.workItemID = workItemID }
      if !figmaURL.isEmpty { config.figmaURL = figmaURL }
      if !slackURL.isEmpty { config.slackChannelURL = slackURL }
      try? config.save(worktree: path, branch: branchName)

      await workspace.refreshClone(commonDir: clone.commonDir, rootURL: clone.rootURL)
      workspace.selectedPath = path.path
      creating = false
      dismiss()
    }
  }

  private func gitCommand(path: URL) -> String {
    let quotedPath = "'\(path.path)'"
    switch source {
    case .newBranch:
      return "git worktree add \(quotedPath) -b '\(effectiveBranch)' 'origin/\(baseBranch)'"
    case .existingBranch:
      if isRemoteSelection {
        return "git worktree add \(quotedPath) --track -b '\(existingLocalName)' '\(existingBranch)'"
      }
      return "git worktree add \(quotedPath) '\(existingBranch)'"
    }
  }
}
