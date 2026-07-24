import SwiftUI
import SwiftData

/// Local, autosaved scratch notes per branch — never committed.
struct NotesSectionBody: View {
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(\.modelContext) private var context
  var worktree: WorktreeInfo
  var branch: String

  @State private var text = ""
  @State private var key = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextEditor(text: $text)
        .font(.body)
        .frame(minHeight: 120)
        .padding(6)
        .background(.background, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .onChange(of: text) { save() }
      Text("Autosaved locally · not shared")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .task { load() }
  }

  private func load() {
    let commonDir = workspace.clone(forWorktree: worktree)?.commonDir ?? worktree.path
    key = BranchNotes.key(commonDir: commonDir, branch: branch)
    let k = key
    let descriptor = FetchDescriptor<BranchNotes>(predicate: #Predicate { $0.key == k })
    text = (try? context.fetch(descriptor).first?.text) ?? ""
  }

  private func save() {
    guard !key.isEmpty else { return }
    let k = key
    let descriptor = FetchDescriptor<BranchNotes>(predicate: #Predicate { $0.key == k })
    if let existing = try? context.fetch(descriptor).first {
      existing.text = text
      existing.updatedAt = .now
    } else {
      context.insert(BranchNotes(key: k, text: text))
    }
    try? context.save()
  }
}
