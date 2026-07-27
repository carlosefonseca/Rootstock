import SwiftUI
import AppKit

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gearshape") }
      AzureSettingsView()
        .tabItem { Label("Azure DevOps", systemImage: "cloud") }
      ShortcutsSettingsView()
        .tabItem { Label("Shortcuts", systemImage: "keyboard") }
    }
    .frame(width: 620, height: 520)
  }
}

/// A reference list of the app's keyboard shortcuts. Not user-customizable —
/// SwiftUI's `.keyboardShortcut` bindings aren't introspectable at runtime, so
/// this is a hand-maintained mirror of what's wired up in `App.swift`,
/// `MainTabBarView`, and `WorktreeDetailView`; keep it in sync when adding or
/// changing a shortcut there.
private struct ShortcutsSettingsView: View {
  private struct Shortcut: Identifiable {
    var action: String
    var keys: String
    var id: String { action }
  }
  private struct Group: Identifiable {
    var title: String
    var items: [Shortcut]
    var id: String { title }
  }

  private let groups: [Group] = [
    Group(title: "Window", items: [
      Shortcut(action: "Refresh All", keys: "⌘R"),
      Shortcut(action: "Pull Request Work", keys: "⌘⇧P"),
    ]),
    Group(title: "Worktrees", items: [
      Shortcut(action: "Next Worktree", keys: "⌘⌥→"),
      Shortcut(action: "Previous Worktree", keys: "⌘⌥←"),
      Shortcut(action: "Reveal in Finder", keys: "⌘⇧R"),
      Shortcut(action: "Open in VS Code", keys: "⌘⇧C"),
      Shortcut(action: "Open in Fork", keys: "⌘⇧K"),
      Shortcut(action: "Toggle Inspector", keys: "⌘I"),
    ]),
    Group(title: "Tabs", items: [
      Shortcut(action: "Switch to Tab 1–9", keys: "⌘1 … ⌘9"),
      Shortcut(action: "Next Tab", keys: "⌃⇥"),
      Shortcut(action: "Previous Tab", keys: "⌃⇧⇥"),
      Shortcut(action: "New Terminal Tab", keys: "⌘T"),
      Shortcut(action: "New Web Tab", keys: "⌘⇧T"),
      Shortcut(action: "Zoom In (terminal font / web page)", keys: "⌘+"),
      Shortcut(action: "Zoom Out (terminal font / web page)", keys: "⌘−"),
      Shortcut(action: "Reset Zoom", keys: "⌘0"),
    ]),
  ]

  var body: some View {
    Form {
      ForEach(groups) { group in
        Section(group.title) {
          ForEach(group.items) { item in
            LabeledContent(item.action) {
              Text(item.keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
          }
        }
      }
      Section {
        Text("Worktree and tab shortcuts apply to whichever worktree window is in front.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct GeneralSettingsView: View {
  @AppStorage(AppSettings.terminalFontNameKey) private var fontName = "Monaco"
  @AppStorage(AppSettings.terminalFontSizeKey) private var fontSize = 12.0

  @State private var monospacedFonts: [String] = []

  /// Every fixed-pitch font actually installed — including any Nerd Fonts — not a
  /// curated shortlist. Filtered to monospaced since a terminal needs a fixed grid.
  ///
  /// `NSFont.isFixedPitch` is unreliable for this: fonts with ligature/contextual
  /// substitution tables (SF Mono Ligaturized, Nerd Font ligaturized variants) report
  /// `false` even when every base glyph advances identically, because the flag reflects
  /// "could a substitution produce a variable-width run" rather than grid uniformity.
  /// Measuring "i" vs "W" advancement catches those fonts too.
  private static func loadMonospacedFonts() -> [String] {
    NSFontManager.shared.availableFonts
      .filter { name in
        guard let f = NSFont(name: name, size: 12) else { return false }
        let narrow = f.advancement(forCGGlyph: CGGlyph(f.glyph(withName: "i"))).width
        let wide = f.advancement(forCGGlyph: CGGlyph(f.glyph(withName: "W"))).width
        return narrow > 0 && narrow == wide
      }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  private var availableFonts: [String] {
    var fonts = monospacedFonts
    if !fonts.isEmpty, !fonts.contains(fontName) { fonts.insert(fontName, at: 0) }
    return fonts.isEmpty ? [fontName] : fonts
  }

  var body: some View {
    Form {
      Section("Terminal") {
        Picker("Font", selection: $fontName) {
          ForEach(availableFonts, id: \.self) { name in
            Text(name).font(.custom(name, size: 13)).tag(name)
          }
        }
        .onChange(of: fontName) { NotificationCenter.default.post(name: .terminalFontChanged, object: nil) }

        LabeledContent("Font size") {
          HStack(spacing: 6) {
            Text("\(String(Int(fontSize))) pt").foregroundStyle(.secondary).monospacedDigit()
            Stepper("", value: $fontSize, in: 8...24, step: 1).labelsHidden()
          }
        }
        .onChange(of: fontSize) { NotificationCenter.default.post(name: .terminalFontChanged, object: nil) }

        Text("The in-app terminal uses this font; changes apply to open sessions immediately.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task {
      if monospacedFonts.isEmpty { monospacedFonts = Self.loadMonospacedFonts() }
    }
  }
}

private struct AzureSettingsView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @State private var orgs: [String] = []
  @State private var azAvailable: Bool?
  @State private var newOrg = ""

  var body: some View {
    Form {
      Section {
        HStack(spacing: 8) {
          Image(systemName: azAvailable == true ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
            .foregroundStyle(azAvailable == true ? .green : .secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(azAvailable == true ? "Signed in with az (AAD)" : "No az session")
            Text("Rootstock uses a PAT when set, otherwise your `az` session. Some orgs require a PAT even with AAD.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }

      Section("Organizations") {
        if orgs.isEmpty {
          Text("Track a clone to discover its Azure DevOps organization, or add one below.")
            .font(.callout).foregroundStyle(.secondary)
        } else {
          ForEach(orgs, id: \.self) { org in
            OrgPATRow(org: org, isManual: AzureSettingsStore.manualOrgs.contains(org),
                      onRemoveOrg: { removeOrg(org) })
          }
        }
        HStack {
          TextField("Add organization (e.g. your-org-name)", text: $newOrg)
            .textFieldStyle(.roundedBorder)
            .onSubmit(addOrg)
          Button("Add") { addOrg() }.disabled(newOrg.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
    .formStyle(.grouped)
    .task {
      orgs = discoverOrgs()
      azAvailable = await AzureAuth.shared.hasAzSession()
    }
  }

  private func addOrg() {
    AzureSettingsStore.addManualOrg(newOrg)
    newOrg = ""
    orgs = discoverOrgs()
  }

  private func removeOrg(_ org: String) {
    AzureSettingsStore.removeManualOrg(org)
    Keychain.delete(org: org)
    orgs = discoverOrgs()
  }

  private func discoverOrgs() -> [String] {
    var set = Set<String>()
    for clone in workspace.clones {
      if let remote = AzureRemote.parse(clone.remoteURL) { set.insert(remote.org) }
    }
    set.formUnion(AzureSettingsStore.manualOrgs)
    return set.sorted()
  }
}

private struct OrgPATRow: View {
  var org: String
  var isManual: Bool
  var onRemoveOrg: () -> Void

  enum TestOutcome { case success(String), failure(String) }

  @State private var pat = ""
  @State private var hasStored = false
  @State private var testing = false
  @State private var testResult: TestOutcome?
  @State private var authMode: AzureSettingsStore.AuthMode = .auto

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(org).font(.headline)
        Spacer()
        if isManual {
          Button("Remove organization", systemImage: "trash") { onRemoveOrg() }
            .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
        }
        Text(hasStored ? "PAT stored" : "az / none")
          .font(.caption)
          .foregroundStyle(hasStored ? .green : .secondary)
      }

      Picker("Authentication", selection: $authMode) {
        ForEach(AzureSettingsStore.AuthMode.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .onChange(of: authMode) { AzureSettingsStore.setAuthMode(authMode, org: org) }

      if authMode != .az {
        HStack {
          SecureField("Personal access token", text: $pat)
            .textFieldStyle(.roundedBorder)
          Button("Save") {
            Keychain.setPAT(pat, org: org)
            hasStored = true
            pat = ""
            testResult = nil
          }
          .disabled(pat.isEmpty)
          if hasStored {
            Button("Remove", role: .destructive) {
              Keychain.delete(org: org)
              hasStored = false
              testResult = nil
            }
          }
        }
      } else {
        Text("Uses your az session — no PAT or keychain access needed.")
          .font(.caption).foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        Button("Test Connection") { test() }
          .disabled(testing)
        if testing { ProgressView().controlSize(.small) }
      }
      // Own row, not crammed into the button's HStack — a long diagnostic
      // message (e.g. an AADSTS error code pulled out of a sign-in page) was
      // getting clipped at 2 lines in a narrow leftover space next to the
      // button instead of wrapping to fill the row.
      switch testResult {
      case .success(let name):
        Label(name, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
          .fixedSize(horizontal: false, vertical: true)
      case .failure(let message):
        Label(message, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      case nil:
        EmptyView()
      }
    }
    .padding(.vertical, 4)
    .task(id: org) {
      authMode = AzureSettingsStore.authMode(org: org)
      // Only probe the keychain when a PAT could actually be used.
      hasStored = authMode != .az && Keychain.pat(org: org) != nil
    }
  }

  private func test() {
    testing = true
    testResult = nil
    Task {
      let result = await AzureClient().testConnection(org: org)
      testing = false
      switch result {
      case .success(let name): testResult = .success("Connected as \(name)")
      case .failure(let error): testResult = .failure(error.localizedDescription)
      }
    }
  }
}
