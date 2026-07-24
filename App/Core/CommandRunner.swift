import Foundation
import Observation

/// A live, streaming command execution used for Makefile actions. Output arrives
/// line-by-line into `output`; the run can be interrupted with SIGINT then SIGKILL.
@Observable
@MainActor
final class CommandRunner {
  private(set) var output: String = ""
  private(set) var isRunning = false
  private(set) var lastExitCode: Int32?
  private(set) var runningLabel: String?

  @ObservationIgnored private var process: Process?

  /// Starts `command` in `directory`. Any prior output is cleared.
  func start(_ command: String, label: String, in directory: URL) {
    guard !isRunning else { return }
    output = ""
    lastExitCode = nil
    runningLabel = label
    isRunning = true

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = directory

    // Force color output from tools that check for a TTY-like environment.
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "xterm-256color"
    env["CLICOLOR"] = "1"
    env["CLICOLOR_FORCE"] = "1"
    process.environment = env

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    self.process = process

    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      let chunk = Self.stripANSI(String(decoding: data, as: UTF8.self))
      Task { @MainActor in self?.output.append(chunk) }
    }

    process.terminationHandler = { [weak self] proc in
      let code = proc.terminationStatus
      pipe.fileHandleForReading.readabilityHandler = nil
      Task { @MainActor in
        self?.isRunning = false
        self?.lastExitCode = code
        self?.runningLabel = nil
        self?.process = nil
      }
    }

    do {
      try process.run()
    } catch {
      output = "Failed to start: \(error.localizedDescription)"
      isRunning = false
      runningLabel = nil
      self.process = nil
    }
  }

  /// Sends SIGINT, then SIGKILL after a short grace period.
  func stop() {
    guard let process, isRunning else { return }
    process.interrupt()
    let pid = process.processIdentifier
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      if process.isRunning { kill(pid, SIGKILL) }
    }
  }

  func clear() {
    output = ""
    lastExitCode = nil
  }

  /// Minimal ANSI/VT100 escape-sequence stripper so the plain text panel reads
  /// cleanly. (A full VT100 terminal is a planned follow-up via SwiftTerm.)
  nonisolated private static func stripANSI(_ string: String) -> String {
    guard string.contains("\u{1B}") else { return string }
    let pattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
    let range = NSRange(string.startIndex..., in: string)
    return regex.stringByReplacingMatches(in: string, range: range, withTemplate: "")
  }
}
