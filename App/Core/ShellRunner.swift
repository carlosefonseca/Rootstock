import Foundation

/// Result of a finished shell command.
struct ShellResult {
  var stdout: String
  var stderr: String
  var exitCode: Int32

  var succeeded: Bool { exitCode == 0 }
  var trimmedOut: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs commands through a login shell so the user's full PATH (Homebrew, Xcode
/// tools, `az`, `opencode`) resolves the same way it does in Terminal. The app
/// ships unsandboxed precisely so it can spawn these binaries at arbitrary paths.
enum ShellRunner {
  /// Runs `command` in `directory` and waits for completion, capturing output.
  static func run(_ command: String, in directory: URL? = nil) async -> ShellResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let directory { process.currentDirectoryURL = directory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
          try process.run()
        } catch {
          continuation.resume(returning: ShellResult(stdout: "", stderr: error.localizedDescription, exitCode: -1))
          return
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        continuation.resume(returning: ShellResult(
          stdout: String(decoding: outData, as: UTF8.self),
          stderr: String(decoding: errData, as: UTF8.self),
          exitCode: process.terminationStatus
        ))
      }
    }
  }
}
