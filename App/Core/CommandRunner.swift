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
  /// Set when the process was ended by a signal (or the shell reports 128+N).
  private(set) var lastSignal: String?

  @ObservationIgnored private var process: Process?

  /// Starts `command` in `directory`. Any prior output is cleared.
  func start(_ command: String, label: String, in directory: URL) {
    guard !isRunning else { return }
    output = "# cwd: \(directory.path)\n\n"
    lastExitCode = nil
    lastSignal = nil
    runningLabel = label
    isRunning = true

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = directory

    var env = ProcessInfo.processInfo.environment
    // When Rootstock is launched from Xcode, its environment carries debugger
    // injection (DYLD_INSERT_LIBRARIES, Main Thread Checker, malloc/NSZombie
    // debugging, ...) that every child inherits. That slows tools like `xcrun`
    // enough to change pipeline timing and doesn't belong in a user's script.
    for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("__XPC_DYLD_")
      || key.hasPrefix("MallocStack") || key.hasPrefix("NSZombie")
      || key == "OS_ACTIVITY_DT_MODE" || key == "LD_LIBRARY_PATH" {
      env[key] = nil
    }
    env["TERM"] = "xterm-256color"
    // Deliberately no CLICOLOR_FORCE: BSD `ls` honors it even when piped, so a
    // script doing `$(ls -dt ...)` got paths wrapped in color escapes and
    // silently stopped finding anything. The panel strips ANSI anyway.
    process.environment = env

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    self.process = process

    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      // Empty data means EOF; stop listening or the handler spins on it.
      guard !data.isEmpty else { handle.readabilityHandler = nil; return }
      let chunk = Self.stripANSI(String(decoding: data, as: UTF8.self))
      Task { @MainActor in self?.output.append(chunk) }
    }

    process.terminationHandler = { [weak self] proc in
      let code = proc.terminationStatus
      // Uncaught signal: status is the signal number. Otherwise a shell
      // reports a signalled child as 128+N (e.g. 141 = SIGPIPE).
      let signalNumber: Int32? = proc.terminationReason == .uncaughtSignal ? code
        : (code > 128 && code < 160 ? code - 128 : nil)
      let signal = signalNumber.map { Self.signalName($0) }
      // Don't detach the reader right away: output the process wrote just
      // before exiting may still be queued in the pipe, and dropping the
      // handler here loses the tail of the log (often the final error). The
      // handler removes itself at EOF; this is only a backstop for when a
      // background child keeps the pipe open.
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        pipe.fileHandleForReading.readabilityHandler = nil
      }
      Task { @MainActor in
        self?.isRunning = false
        self?.lastExitCode = code
        self?.lastSignal = signal
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
    lastSignal = nil
  }

  nonisolated private static func signalName(_ n: Int32) -> String {
    let names: [Int32: String] = [
      1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 6: "SIGABRT", 9: "SIGKILL",
      11: "SIGSEGV", 13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM",
    ]
    return names[n] ?? "signal \(n)"
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
