import AppKit
import SwiftTerm

/// The terminal view the app actually uses, adding two behaviours SwiftTerm
/// doesn't ship: copy-on-select, and Finder drops that type the dropped file's
/// path (what Terminal.app and iTerm2 both do).
final class RootstockTerminalView: LocalProcessTerminalView {
  /// Copies the selection to the clipboard as it's made — the "select to copy"
  /// convention most terminal emulators (Terminal.app, iTerm2) follow, instead
  /// of requiring an explicit Cmd+C. `selectionChanged` is `open` on
  /// `TerminalView` but the `selection` property backing `copy(_:)` is
  /// module-internal, so this goes through the public `getSelection()` instead
  /// of reimplementing what `copy(_:)` already does.
  override func selectionChanged(source: Terminal) {
    super.selectionChanged(source: source)
    guard let text = getSelection(), !text.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  // MARK: Drag destination

  /// SwiftTerm registers no dragged types at all, which is why a file dragged
  /// from Finder was silently refused. Registered here rather than at
  /// construction because `LocalProcessTerminalView.init(frame:)` is `public`,
  /// not `open`, so it can't be overridden from outside the package — and the
  /// call is idempotent, so running it again on every window change is fine.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    registerForDraggedTypes([.fileURL, .string])
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedText(from: sender) == nil ? [] : .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedText(from: sender) == nil ? [] : .copy
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let text = droppedText(from: sender) else { return false }
    // A drop onto an unfocused tab should leave it ready to keep typing, the
    // same as clicking into it would.
    window?.makeFirstResponder(self)
    sendAsPaste(text)
    // Outside the paste, not inside it: a shell treats the two the same, but a
    // TUI matching the pasted text against a path shouldn't have to cope with
    // trailing whitespace.
    if isFileDrop(sender) { send(txt: " ") }
    return true
  }

  /// Delivers a drop the way Cmd+V would rather than as keystrokes. Apps that
  /// enable bracketed paste (mode 2004) — Claude Code and opencode among them —
  /// only turn a dropped path into a file tag when it arrives as a single
  /// paste, and a shell can't accidentally *run* a multi-line paste. SwiftTerm
  /// wraps its own Cmd+V this way but its `insertText(_:_:isPaste:)` is
  /// package-internal, so this reassembles the same sequence from the public
  /// pieces.
  private func sendAsPaste(_ text: String) {
    let bracketed = getTerminal().bracketedPasteMode
    if bracketed { send(data: EscapeSequences.bracketedPasteStart[0...]) }
    send(txt: text)
    if bracketed { send(data: EscapeSequences.bracketedPasteEnd[0...]) }
  }

  private func isFileDrop(_ sender: NSDraggingInfo) -> Bool {
    sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true])
  }

  /// What the drop should type into the shell: shell-quoted paths for a file
  /// drag (space-separated, so several files land as separate arguments), or
  /// the text itself for a text drag.
  private func droppedText(from sender: NSDraggingInfo) -> String? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
       !urls.isEmpty {
      return urls.map { Self.shellQuoted($0.path) }.joined(separator: " ")
    }
    // Finder puts the file's name on the pasteboard as plain text too, so this
    // is only reached for genuine text/link drags — never as a fallback for a
    // file whose URL failed to read.
    if let text = sender.draggingPasteboard.string(forType: .string), !text.isEmpty {
      return text
    }
    return nil
  }

  /// Quotes a path the shell would otherwise mangle — spaces being the common
  /// case, but also globs, `$`, and parentheses. Anything made only of
  /// characters every shell passes through verbatim is left bare, so the usual
  /// path stays readable on the command line.
  static func shellQuoted(_ path: String) -> String {
    let literal = CharacterSet(charactersIn:
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/@%+=:,")
    guard path.isEmpty || path.unicodeScalars.contains(where: { !literal.contains($0) }) else { return path }
    // Single quotes protect everything except a single quote itself, which has
    // to close the run, escape, and reopen: don't  ->  'don'\''t'
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
