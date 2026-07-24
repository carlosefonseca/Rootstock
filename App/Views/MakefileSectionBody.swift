import SwiftUI

struct MakefileSectionBody: View {
  var worktree: WorktreeInfo
  @State private var targets: [MakeTarget] = []
  @State private var runner = CommandRunner()

  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if targets.isEmpty {
        Text("No documented targets found. Add `## description` comments to Makefile targets.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
          ForEach(targets) { target in
            Button {
              runner.start("make \(target.name)", label: target.name, in: worktree.url)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.callout.weight(.medium))
                Text(target.help)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                  .multilineTextAlignment(.leading)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(8)
              .contentShape(.rect)
            }
            .buttonStyle(.bordered)
            .disabled(runner.isRunning)
            .help(target.help)
          }
        }
      }

      if runner.isRunning || !runner.output.isEmpty || runner.lastExitCode != nil {
        CommandOutputPanel(runner: runner, worktree: worktree)
      }
    }
    .task {
      targets = MakefileParser.targets(in: worktree.url)
    }
  }
}

/// The fixed ~12-line inline output panel below the button grid.
struct CommandOutputPanel: View {
  @Bindable var runner: CommandRunner
  var worktree: WorktreeInfo

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        if runner.isRunning {
          ProgressView().controlSize(.small)
          Text("make \(runner.runningLabel ?? "")").font(.caption.monospaced())
        } else if let code = runner.lastExitCode {
          Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(code == 0 ? .green : .red)
          Text(code == 0 ? "Done" : "Exit \(code)").font(.caption)
        }
        Spacer()
        if runner.isRunning {
          Button("Stop", systemImage: "stop.fill") { runner.stop() }
            .controlSize(.small)
        }
        Button("Clear", systemImage: "trash") { runner.clear() }
          .controlSize(.small)
          .disabled(runner.isRunning)
      }
      .padding(8)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          Text(runner.output.isEmpty ? " " : runner.output)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .id("bottom-anchor")
        }
        .frame(height: 190)
        .onChange(of: runner.output) {
          withAnimation { proxy.scrollTo("bottom-anchor", anchor: .bottom) }
        }
      }
    }
    .background(.black.opacity(0.85), in: .rect(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    .foregroundStyle(.white)
    .tint(.white)
  }
}
