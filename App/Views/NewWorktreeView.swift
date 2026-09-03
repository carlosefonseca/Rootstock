import SwiftUI
import AppKit

/// Creates a worktree — either for a brand-new branch or an existing one — and
/// writes its shared config in one step, pre-filling the work item id.
struct NewWorktreeView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(\.dismiss) private var dismiss

  enum Source: String, CaseIterable, Identifiable {
    case newBranch, existingBranch, pullRequest
    var id: String { rawValue }
    var label: String {
      switch self {
      case .newBranch: return "New branch"
      case .existingBranch: return "Existing branch"
      case .pullRequest: return "Pull request"
      }
    }
  }

  enum WorkItemType: String, CaseIterable, Identifiable {
    case feature = "feature", bugfix = "bugfix", chore = "chore"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
  }

  @State private var source: Source = .newBranch
  @State private var selectedCloneID: String?
  @State private var workItemURLText = ""
  @State private var title = ""
  @State private var type: WorkItemType = .feature
  @State private var branchEdited = false
  @State private var branch = ""
  @State private var folderNameEdited = false
  @State private var folderName = ""
  @State private var baseBranch = "develop"
  @State private var bookmarks: [Bookmark] = []
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

  // Pull-request state.
  @State private var prs: [ADOPullRequest] = []
  @State private var selectedPRId: Int?
  @State private var prSearchText = ""
  @State private var prLoading = false
  @State private var prError: String?

  private var selectedClone: TrackedClone? {
    workspace.clones.first { $0.commonDir == selectedCloneID }
  }

  private var isRemoteSelection: Bool { existingBranch.hasPrefix("origin/") }
  private var existingLocalName: String {
    isRemoteSelection ? String(existingBranch.dropFirst("origin/".count)) : existingBranch
  }

  private var selectedPR: ADOPullRequest? {
    guard let selectedPRId else { return nil }
    return prs.first { $0.id == selectedPRId }
  }

  /// A worktree for the selected PR's branch already exists — offer to jump
  /// to it instead of creating a duplicate one.
  private var existingWorktreeForSelectedPR: WorktreeInfo? {
    guard let selectedPR, let clone = selectedClone, let sourceBranch = selectedPR.sourceBranch else { return nil }
    return workspace.worktree(in: clone, branch: sourceBranch)
  }

  private var parsedWorkItem: WorkItemURL? { WorkItemURL.parse(workItemURLText) }

  private var derivedBranch: String {
    let slug = title
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let idPart = parsedWorkItem.map { "\($0.id)-" } ?? ""
    return "\(type.rawValue)/\(idPart)\(slug)"
  }

  /// Characters git rejects in a ref name (control chars, space, and
  /// `~^:?*[\`) — replaced with `-` as the user types rather than left to
  /// surface as a shell/git error only once they hit Create.
  private static let branchInvalidCharacters: CharacterSet = {
    var set = CharacterSet(charactersIn: " ~^:?*[\\")
    set.formUnion(.controlCharacters)
    return set
  }()

  private func sanitizeBranchInput(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.map {
      Self.branchInvalidCharacters.contains($0) ? Unicode.Scalar("-") : $0
    }))
  }

  /// A folder name is a single path component, so `/` (which would create a
  /// nested directory) gets collapsed just like it is in the derived default.
  private func sanitizeFolderInput(_ text: String) -> String {
    sanitizeBranchInput(text).replacingOccurrences(of: "/", with: "-")
  }

  private var effectiveBranch: String {
    switch source {
    case .newBranch: return branchEdited ? branch : derivedBranch
    case .existingBranch, .pullRequest: return existingLocalName
    }
  }

  private var derivedFolderName: String {
    effectiveBranch.replacingOccurrences(of: "/", with: "-")
  }

  private var effectiveFolderName: String {
    folderNameEdited ? folderName : derivedFolderName
  }

  private var targetPath: URL? {
    guard let parent = parentDir ?? selectedClone?.rootURL.deletingLastPathComponent(),
          !effectiveFolderName.isEmpty else { return nil }
    return parent.appending(path: effectiveFolderName)
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

        switch source {
        case .existingBranch: existingBranchSection
        case .pullRequest: pullRequestSection
        case .newBranch: newBranchSection
        }

        Section("Work item") {
          HStack {
            TextField("Work item URL", text: $workItemURLText,
                       prompt: Text("https://dev.azure.com/org/project/_workitems/edit/205552"))
            Button("Fetch", systemImage: "arrow.down.circle") { fetchWorkItem() }
              .labelStyle(.iconOnly)
              .disabled(parsedWorkItem == nil || fetching)
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
          BranchPickerField(title: "Base branch (PRJ_DEP)", selection: $baseBranch,
                            localBranches: localBranches, remoteBranches: remoteBranches)
        }
        Section {
          BookmarkListEditor(bookmarks: $bookmarks)
        } header: {
          Text("Bookmarks")
        } footer: {
          Text("Links shown in the inspector and new-tab menu. Slack URLs open in the native app.")
            .font(.caption2)
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
        Button(existingWorktreeForSelectedPR != nil ? "Open Worktree" : "Create Worktree") { create() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate || creating)
      }
      .padding(16)
    }
    .frame(width: 520, height: 640)
    .onAppear { if selectedCloneID == nil { selectedCloneID = workspace.clones.first?.commonDir } }
    .onChange(of: selectedCloneID) { reloadBranches(); loadPullRequests() }
    .onChange(of: existingBranch) { folderNameEdited = false }
    .onChange(of: source) { reloadBranches(); loadPullRequests() }
    .onChange(of: selectedPRId) {
      guard let sourceBranch = selectedPR?.sourceBranch else { return }
      existingBranch = localBranches.contains(sourceBranch) ? sourceBranch : "origin/\(sourceBranch)"
    }
  }

  @ViewBuilder private var newBranchSection: some View {
    Section("Branch") {
      TextField("Branch", text: Binding(
        get: { effectiveBranch },
        set: { branch = sanitizeBranchInput($0); branchEdited = true }))
        .font(.body.monospaced())
      BranchPickerField(title: "Base branch", selection: $baseBranch,
                        localBranches: localBranches, remoteBranches: remoteBranches)
      folderNameField
      locationRow
    }
  }

  @ViewBuilder private var existingBranchSection: some View {
    Section("Branch") {
      // `stripsRemotePrefix: false` — `origin/` here means "create a local
      // branch tracking that remote", which `gitCommand` keys off.
      BranchPickerField(title: "Branch", selection: $existingBranch,
                        localBranches: localBranches, remoteBranches: remoteBranches,
                        stripsRemotePrefix: false)
      if !existingBranch.isEmpty {
        Text(isRemoteSelection
             ? "Creates local branch \(existingLocalName) tracking \(existingBranch)."
             : "Selected: \(existingBranch)")
          .font(.caption).foregroundStyle(.secondary)
      }
      folderNameField
      locationRow
    }
  }

  @ViewBuilder private var folderNameField: some View {
    TextField("Folder name", text: Binding(
      get: { effectiveFolderName },
      set: { folderName = sanitizeFolderInput($0); folderNameEdited = true }))
      .font(.body.monospaced())
  }

  private var filteredPRs: [ADOPullRequest] {
    guard !prSearchText.isEmpty else { return prs }
    return prs.filter {
      $0.title.localizedCaseInsensitiveContains(prSearchText) ||
      ($0.sourceBranch?.localizedCaseInsensitiveContains(prSearchText) ?? false) ||
      String($0.pullRequestId).contains(prSearchText)
    }
  }

  @ViewBuilder private var pullRequestSection: some View {
    Section("Pull Request") {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search pull requests", text: $prSearchText)
          .textFieldStyle(.plain)
        if prLoading { ProgressView().controlSize(.small) }
        if !prSearchText.isEmpty {
          Button {
            prSearchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      if let prError {
        Label(prError, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
      List(selection: $selectedPRId) {
        ForEach(filteredPRs) { pr in
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text("#\(pr.pullRequestId)").font(.caption.monospaced()).foregroundStyle(.secondary)
              Text(pr.title).lineLimit(1)
              if pr.isDraft ?? false { StatusPill(text: "Draft", tint: .gray) }
            }
            if let sourceBranch = pr.sourceBranch {
              Text(sourceBranch).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
          }
          .tag(pr.id)
        }
        if !prLoading && prError == nil && filteredPRs.isEmpty {
          Text(prs.isEmpty ? "No active pull requests." : "No matching pull requests.")
            .foregroundStyle(.secondary)
        }
      }
      .frame(height: 160)

      if selectedPR != nil {
        if let existing = existingWorktreeForSelectedPR {
          Label("Worktree already exists at \(existing.path)", systemImage: "checkmark.circle")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Text(isRemoteSelection
               ? "Creates local branch \(existingLocalName) tracking \(existingBranch)."
               : "Checks out existing local branch \(existingBranch) (not currently in a worktree).")
            .font(.caption).foregroundStyle(.secondary)
          folderNameField
          locationRow
        }
      }
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
    guard !creating else { return false }
    if source == .pullRequest, existingWorktreeForSelectedPR != nil { return true }
    guard selectedClone != nil, targetPath != nil else { return false }
    switch source {
    case .newBranch: return !effectiveBranch.hasSuffix("/") && !effectiveBranch.isEmpty && !baseBranch.isEmpty
    case .existingBranch: return !existingBranch.isEmpty
    case .pullRequest: return selectedPR != nil
    }
  }

  private func reloadBranches() {
    fetchedTitle = nil
    existingBranch = ""
    // Always fetched, not just for the existing-branch/new-branch tabs: the
    // Shared Config section's base-branch picker needs this regardless of
    // which source tab is active.
    guard let clone = selectedClone else { return }
    Task {
      let result = await Git.branches(in: clone.rootURL)
      localBranches = result.local
      // Hide remotes that already have a local branch of the same name.
      let localSet = Set(result.local)
      remoteBranches = result.remote.filter { !localSet.contains(String($0.dropFirst("origin/".count))) }
    }
  }

  private func loadPullRequests() {
    prError = nil
    prSearchText = ""
    selectedPRId = nil
    prs = []
    guard source == .pullRequest, let clone = selectedClone else { return }
    guard let remote = AzureRemote.parse(clone.remoteURL) else {
      prError = "No Azure DevOps remote found for this clone."
      return
    }
    prLoading = true
    Task {
      async let branchResult = Git.branches(in: clone.rootURL)
      do {
        prs = try await AzureService().pullRequests(remote: remote)
      } catch {
        prError = error.localizedDescription
      }
      localBranches = await branchResult.local
      prLoading = false
    }
  }

  /// Looks the work item up in Azure DevOps and pre-fills title + type. The
  /// org/project/id all come from the pasted URL — no separate lookup needed.
  private func fetchWorkItem() {
    guard let workItem = parsedWorkItem else { return }
    fetching = true
    fetchError = nil
    Task {
      do {
        let item = try await AzureService().workItem(org: workItem.org, project: workItem.project, id: workItem.id)
        fetchedTitle = item.title
        if source == .newBranch {
          if let fetchedTitle = item.title { title = fetchedTitle }
          if let fetchedType = item.type { type = mapType(fetchedType) }
        }
      } catch {
        let scope = workItem.project.map { "\(workItem.org)/\($0)" } ?? workItem.org
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
    if source == .pullRequest, let existing = existingWorktreeForSelectedPR {
      workspace.selectedPath = existing.path
      dismiss()
      return
    }
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
      if let parsedWorkItem { config.workItemURLs = [parsedWorkItem.canonical] }
      config.bookmarks = bookmarks.filter { !$0.title.isEmpty && !$0.urlString.isEmpty }
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
    case .existingBranch, .pullRequest:
      if isRemoteSelection {
        return "git worktree add \(quotedPath) --track -b '\(existingLocalName)' '\(existingBranch)'"
      }
      return "git worktree add \(quotedPath) '\(existingBranch)'"
    }
  }
}
