import SwiftUI

/// What the editor sheet is doing — `Identifiable` so it can drive `.sheet(item:)`.
private struct ActionDraft: Identifiable {
  enum Mode { case add, edit(CustomAction.ID) }
  let id = UUID()
  var mode: Mode
  var name: String
  var command: String
}

/// The "Custom Actions" card body: user-defined shell commands, run in the
/// worktree and streamed into the same output panel Makefile actions use.
struct CustomActionsSectionBody: View {
  @Environment(CustomActionsStore.self) private var store
  var worktree: WorktreeInfo
  @State private var runner = CommandRunner()
  @State private var draft: ActionDraft?
  @State private var pendingDelete: CustomAction?

  var body: some View {
    let actions = store.actions(for: worktree)
    VStack(alignment: .leading, spacing: 8) {
      if actions.isEmpty {
        Text("No custom actions yet. Add a shell command to run in this worktree.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ForEach(actions) { action in
        Button {
          runner.start(action.command, label: action.name, in: worktree.url)
        } label: {
          VStack(alignment: .leading, spacing: 1) {
            Text(action.name).font(.callout.weight(.medium))
            Text(action.command)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 6)
          .padding(.leading, 8)
          .padding(.trailing, 24)
          .overlay(alignment: .trailing) {
            Image(systemName: "play.fill")
              .font(.caption2)
              .foregroundStyle(.tint)
              .padding(.trailing, 8)
          }
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(runner.isRunning)
        .help(action.command)
        .contextMenu {
          Button("Edit…", systemImage: "pencil") {
            draft = ActionDraft(mode: .edit(action.id), name: action.name, command: action.command)
          }
          Button("Duplicate & Edit…", systemImage: "plus.square.on.square") {
            draft = ActionDraft(mode: .add, name: "\(action.name) copy", command: action.command)
          }
          Divider()
          Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = action }
        }
      }

      Button("Add Action", systemImage: "plus") {
        draft = ActionDraft(mode: .add, name: "", command: "")
      }
      .buttonStyle(.plain)
      .font(.caption)
      .foregroundStyle(.tint)

      if runner.isRunning || !runner.output.isEmpty || runner.lastExitCode != nil {
        CommandOutputPanel(runner: runner, worktree: worktree)
      }
    }
    .sheet(item: $draft) { draft in
      CustomActionEditor(draft: draft, worktree: worktree) { name, command in
        switch draft.mode {
        case .add:
          store.add(CustomAction(name: name, command: command), to: worktree)
        case .edit(let id):
          store.update(CustomAction(id: id, name: name, command: command), in: worktree)
        }
      }
    }
    .confirmationDialog("Delete Action?", isPresented: Binding(
      get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
    ), presenting: pendingDelete) { action in
      Button("Delete \"\(action.name)\"", role: .destructive) { store.remove(action, from: worktree) }
      Button("Cancel", role: .cancel) {}
    }
  }
}

private struct CustomActionEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(WorkspaceModel.self) private var workspace
  @Environment(CustomActionsStore.self) private var store
  var draft: ActionDraft
  var worktree: WorktreeInfo
  var onSave: (String, String) -> Void

  @State private var name: String
  @State private var command: String

  init(draft: ActionDraft, worktree: WorktreeInfo, onSave: @escaping (String, String) -> Void) {
    self.draft = draft
    self.worktree = worktree
    self.onSave = onSave
    _name = State(initialValue: draft.name)
    _command = State(initialValue: draft.command)
  }

  private var isEditing: Bool {
    if case .edit = draft.mode { return true }
    return false
  }

  /// Other worktrees that have actions, each with their actions.
  private var sources: [(worktree: WorktreeInfo, actions: [CustomAction])] {
    workspace.orderedWorktrees
      .filter { $0.path != worktree.path }
      .map { ($0, store.actions(for: $0)) }
      .filter { !$0.1.isEmpty }
  }

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
      && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(isEditing ? "Edit Action" : "New Action").font(.headline)
        Spacer()
        Menu("Pick from Other Worktree", systemImage: "square.and.arrow.down") {
          ForEach(sources, id: \.worktree.path) { source in
            Section(source.worktree.folderName) {
              ForEach(source.actions) { action in
                Button(action.name) {
                  name = action.name
                  command = action.command
                }
              }
            }
          }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(sources.isEmpty)
      }

      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)

      VStack(alignment: .leading, spacing: 4) {
        Text("Command").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $command)
          .font(.system(.body, design: .monospaced))
          .autocorrectionDisabled()
          .frame(height: 90)
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        Text("Runs with zsh in the worktree's folder.")
          .font(.caption2).foregroundStyle(.tertiary)
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          onSave(name.trimmingCharacters(in: .whitespaces),
                 command.trimmingCharacters(in: .whitespacesAndNewlines))
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
      }
    }
    .padding(16)
    .frame(width: 420)
  }
}
