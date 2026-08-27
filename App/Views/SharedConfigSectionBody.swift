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
  @State private var bookmarks: [Bookmark] = []
  @State private var loaded = BranchConfig()
  @State private var localBranches: [String] = []
  @State private var remoteBranches: [String] = []

  @State private var saveError: String?

  private var isBranchDirty: Bool {
    baseBranch != (loaded.prjDep ?? "") ||
    workItemURLs.filter({ !$0.isEmpty }) != loaded.workItemURLs ||
    additionalPRURLs.filter({ !$0.isEmpty }) != loaded.additionalPRURLs ||
    bookmarks != loaded.bookmarks
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Shared Config").font(.title2.weight(.semibold)).padding([.horizontal, .top], 20)
      Text(BranchConfig.fileName(forBranch: branch))
        .font(.caption.monospaced()).foregroundStyle(.secondary)
        .padding(.horizontal, 20)

      Form {
        Section("Branch — \(branch)") {
          BranchPickerField(title: "Base branch (PRJ_DEP)", selection: $baseBranch,
                            localBranches: localBranches, remoteBranches: remoteBranches,
                            prompt: "develop")
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
        Section {
          BookmarkListEditor(bookmarks: $bookmarks)
        } header: {
          Text("Bookmarks")
        } footer: {
          Text("Links shown in the inspector and new-tab menu. Slack URLs open in the native app.")
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
          .disabled(!isBranchDirty)
      }
      .padding(16)
    }
    .frame(width: 640, height: 680)
    .task { load() }
    .task { await loadBranches() }
  }

  private func load() {
    loaded = BranchConfig.load(worktree: worktree.url, branch: branch)
    baseBranch = loaded.prjDep ?? ""
    workItemURLs = loaded.workItemURLs
    additionalPRURLs = loaded.additionalPRURLs
    bookmarks = loaded.bookmarks
  }

  private func loadBranches() async {
    let result = await Git.branches(in: worktree.url)
    localBranches = result.local
    // Hide remotes that already have a local branch of the same name, matching
    // how `NewWorktreeView` presents the same list.
    let localSet = Set(result.local)
    remoteBranches = result.remote.filter { !localSet.contains(String($0.dropFirst("origin/".count))) }
  }

  private func save() {
    do {
      var config = BranchConfig.load(worktree: worktree.url, branch: branch) // keep passthrough lines
      config.prjDep = baseBranch.isEmpty ? nil : baseBranch
      config.workItemURLs = workItemURLs.filter { !$0.isEmpty }
      config.additionalPRURLs = additionalPRURLs.filter { !$0.isEmpty }
      config.bookmarks = bookmarks.filter { !$0.title.isEmpty && !$0.urlString.isEmpty }
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

struct BookmarkListEditor: View {
  @Binding var bookmarks: [Bookmark]
  @FocusState private var focusedField: BookmarkField?

  enum BookmarkField: Hashable {
    case title(UUID)
    case url(UUID)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach($bookmarks) { $bookmark in
        HStack(alignment: .top, spacing: 8) {
          VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $bookmark.title, prompt: Text("e.g. Figma"))
              .labelsHidden()
              .focused($focusedField, equals: .title(bookmark.id))
            TextField("URL", text: $bookmark.urlString, prompt: Text("https://…"))
              .labelsHidden()
              .focused($focusedField, equals: .url(bookmark.id))
          }
          HStack(spacing: 4) {
            Button("Open", systemImage: "arrow.up.right.square") {
              if bookmark.prefersNativeApp {
                AppOpener.openSlack(bookmark.urlString)
              } else {
                AppOpener.open(bookmark.urlString)
              }
            }
            .labelStyle(.iconOnly)
            .disabled(bookmark.urlString.isEmpty)
            Button("Remove", systemImage: "minus.circle") {
              bookmarks.removeAll { $0.id == bookmark.id }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
          }
          .padding(.top, 2)
        }
      }
      Button("Add Bookmark", systemImage: "plus.circle") {
        let b = Bookmark(title: "", urlString: "")
        bookmarks.append(b)
        focusedField = .title(b.id)
      }
      .labelStyle(.titleAndIcon)
    }
  }
}
