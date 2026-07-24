import SwiftUI

struct MakefileSectionBody: View {
  var worktree: WorktreeInfo
  @State private var targets: [MakeTarget] = []
  @State private var runner = CommandRunner()
  @State private var expanded = false

  /// Targets the team reaches for most, surfaced first when collapsed.
  private static let priority = ["setup", "open"]
  private static let collapsedCount = 4

  private var ordered: [MakeTarget] {
    let priorityTargets = Self.priority.compactMap { name in targets.first { $0.name == name } }
    let rest = targets.filter { !Self.priority.contains($0.name) }
    return priorityTargets + rest
  }

  private var visible: [MakeTarget] {
    expanded ? ordered : Array(ordered.prefix(Self.collapsedCount))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if targets.isEmpty {
        Text("No documented targets found. Add `## description` comments to Makefile targets.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(visible) { target in
          Button {
            runner.start("make \(target.name)", label: target.name, in: worktree.url)
          } label: {
            // The play icon is pinned via a trailing overlay on the full-width
            // label rather than an HStack + Spacer — with a Spacer, the icon's
            // exact position could drift a few points row to row depending on
            // how the button's intrinsic width interacted with long text; an
            // overlay anchors it to the same edge regardless of content.
            VStack(alignment: .leading, spacing: 1) {
              Text(target.name).font(.callout.weight(.medium))
              Text(target.help)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.leading, 8)
            .padding(.trailing, 24)
            .contentShape(.rect)
            .overlay(alignment: .trailing) {
              Image(systemName: "play.fill")
                .font(.caption2)
                .foregroundStyle(.tint)
                .padding(.trailing, 8)
            }
          }
          .buttonStyle(.bordered)
          .frame(maxWidth: .infinity, alignment: .leading)
          .disabled(runner.isRunning)
          .help(target.help)
        }

        if ordered.count > Self.collapsedCount {
          Button(expanded ? "Show fewer" : "Show \(ordered.count - Self.collapsedCount) more…") {
            withAnimation(.snappy) { expanded.toggle() }
          }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(.tint)
        }
      }

      if runner.isRunning || !runner.output.isEmpty || runner.lastExitCode != nil {
        CommandOutputPanel(runner: runner, worktree: worktree)
      }
    }
    .task(id: worktree.path) {
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
