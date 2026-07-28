import AppKit
import SwiftUI

/// Safari-style chrome — back/forward/reload plus an address bar — wrapping the
/// live `WKWebView` for one web tab.
struct WebTabPane: View {
  var session: WebTabSession
  @State private var addressText: String = ""
  @FocusState private var addressFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      WebTabViewRepresentable(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear {
      addressText = displayString(session.currentURLString)
      // A brand-new blank tab has nowhere useful to put the cursor but the
      // address bar — jump straight there instead of making it a click away.
      if session.currentURLString == "about:blank" {
        addressFocused = true
      }
    }
    .onChange(of: session.currentURLString) { _, new in
      if !addressFocused { addressText = displayString(new) }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      HStack(spacing: 4) {
        Button("Back", systemImage: "chevron.left") { session.goBack() }
          .disabled(!session.canGoBack)
        Button("Forward", systemImage: "chevron.right") { session.goForward() }
          .disabled(!session.canGoForward)
      }
      Button(session.isLoading ? "Stop" : "Reload",
             systemImage: session.isLoading ? "xmark" : "arrow.clockwise") {
        session.reloadOrStop()
      }

      TextField("Search or enter website name", text: $addressText)
        .textFieldStyle(.roundedBorder)
        .focused($addressFocused)
        .onSubmit { session.load(addressText) }

      Button("Copy Page Link", systemImage: "link") { copyPageLink() }
        .disabled(session.currentURLString == "about:blank")
        .keyboardShortcut("c", modifiers: [.command, .shift])

      if session.isLoading {
        ProgressView().controlSize(.small)
      }
    }
    .labelStyle(.iconOnly)
    .controlSize(.regular)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  private func displayString(_ url: String) -> String {
    url == "about:blank" ? "" : url
  }

  private func copyPageLink() {
    guard session.currentURLString != "about:blank" else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(session.currentURLString, forType: .string)
  }
}
