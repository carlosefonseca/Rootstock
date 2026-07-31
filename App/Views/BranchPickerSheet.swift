import SwiftUI

/// A searchable, scrollable branch picker presented as its own sheet.
///
/// Pulled out of `NewWorktreeView`'s inline list because a `List` nested
/// inside that view's `Form` fought the enclosing scroll view for gestures
/// and never scrolled reliably. As a standalone sheet it gets a real list
/// and a native search field.
struct BranchPickerSheet: View {
  var localBranches: [String]
  var remoteBranches: [String]
  var selected: String?
  var onSelect: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""
  /// Focused on open — with a hundred-odd branches, filtering is what you came
  /// here to do, so it shouldn't cost a click first.
  @FocusState private var searchFocused: Bool

  private func filtered(_ branches: [String]) -> [String] {
    searchText.isEmpty ? branches : branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
  }

  var body: some View {
    NavigationStack {
      List {
        let local = filtered(localBranches)
        let remote = filtered(remoteBranches)
        if !local.isEmpty {
          Section("Local") { ForEach(local, id: \.self, content: row) }
        }
        if !remote.isEmpty {
          Section("Remote") { ForEach(remote, id: \.self, content: row) }
        }
        if local.isEmpty && remote.isEmpty {
          Text(searchText.isEmpty ? "No branches." : "No matching branches.")
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Select Branch")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .searchable(text: $searchText, placement: .toolbar, prompt: "Search branches")
    .searchFocused($searchFocused)
    .frame(width: 420, height: 480)
    .onAppear { searchFocused = true }
  }

  private func row(_ branch: String) -> some View {
    Button {
      onSelect(branch)
      dismiss()
    } label: {
      HStack {
        Text(branch).font(.body.monospaced())
        Spacer()
        if branch == selected {
          Image(systemName: "checkmark").foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// A form row showing the currently selected branch with a button that opens
/// `BranchPickerSheet`. The form-facing half of the picker, so every place that
/// asks for a branch looks and behaves the same.
struct BranchPickerField: View {
  var title: String
  @Binding var selection: String
  var localBranches: [String]
  var remoteBranches: [String]
  /// Whether picking `origin/foo` should store just `foo`. True for fields that
  /// name a branch (a config's base branch); false where the `origin/` prefix
  /// is meaningful — checking one out has to know to create a tracking branch.
  var stripsRemotePrefix = true
  var prompt = "Choose…"

  @State private var showingPicker = false

  var body: some View {
    LabeledContent(title) {
      HStack {
        Text(selection.isEmpty ? prompt : selection)
          .font(.body.monospaced())
          .foregroundStyle(selection.isEmpty ? .secondary : .primary)
          .lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("Choose…") { showingPicker = true }.controlSize(.small)
      }
    }
    .sheet(isPresented: $showingPicker) {
      BranchPickerSheet(localBranches: localBranches, remoteBranches: remoteBranches,
                        selected: selection) { picked in
        selection = stripsRemotePrefix && picked.hasPrefix("origin/")
          ? String(picked.dropFirst("origin/".count))
          : picked
      }
    }
  }
}
