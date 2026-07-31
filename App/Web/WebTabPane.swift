import AppKit
import SwiftUI

/// Safari-style chrome — back/forward/reload plus an address bar — wrapping the
/// live `WKWebView` for one web tab.
struct WebTabPane: View {
  var session: WebTabSession
  @State private var addressText: String = ""
  @FocusState private var addressFocused: Bool
  /// Non-nil while the zoom readout is on screen. Transient by design — the
  /// zoom level isn't worth permanent chrome, it just needs to confirm what a
  /// Cmd+/Cmd- press actually did. "Reset Zoom" lives in the tab's menu.
  @State private var zoomIndicator: Double?
  @State private var zoomIndicatorTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      WebTabViewRepresentable(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { zoomOverlay }
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
    .onChange(of: session.userZoomCount) { showZoomIndicator() }
  }

  @ViewBuilder private var zoomOverlay: some View {
    if let zoomIndicator {
      Text("\(Int((zoomIndicator * 100).rounded()))%")
        .font(.callout.weight(.medium).monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 6, y: 2)
        .padding(.top, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .allowsHitTesting(false)
    }
  }

  private func showZoomIndicator() {
    zoomIndicatorTask?.cancel()
    withAnimation(.snappy(duration: 0.15)) { zoomIndicator = session.pageZoom }
    zoomIndicatorTask = Task {
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.25)) { zoomIndicator = nil }
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
