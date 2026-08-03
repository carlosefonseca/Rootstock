import AppKit
import WebKit

/// A `WKWebView` that lets its owner prepend items to the native right-click
/// menu. WebKit's context-menu customization API (`WKUIDelegate`'s
/// `contextMenuConfigurationFor`) is iOS-only, but the AppKit menu WebKit builds
/// still routes through `NSView.willOpenMenu(_:with:)` — enough to insert our
/// own items above WebKit's, without replacing any of them.
final class WebContextMenuWebView: WKWebView {
  /// Rebuilt on every open, not configured once: which actions apply depends on
  /// what's under the cursor for *this* right-click.
  var additionalMenuItems: (() -> [NSMenuItem])?

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)
    let items = additionalMenuItems?() ?? []
    guard !items.isEmpty else { return }
    for (offset, item) in items.enumerated() {
      menu.insertItem(item, at: offset)
    }
    menu.insertItem(.separator(), at: items.count)
  }
}
