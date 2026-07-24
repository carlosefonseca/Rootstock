import SwiftUI
import AppKit

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gearshape") }
      AzureSettingsView()
        .tabItem { Label("Azure DevOps", systemImage: "cloud") }
    }
    .frame(width: 540, height: 460)
  }
}

private struct GeneralSettingsView: View {
  @AppStorage(AppSettings.terminalAppPathKey) private var terminalAppPath = AppSettings.defaultTerminalAppPath
  @AppStorage(AppSettings.terminalFontNameKey) private var fontName = "Menlo"
  @AppStorage(AppSettings.terminalFontSizeKey) private var fontSize = 12.0

  @State private var terminalApps: [URL] = []
  @State private var monospacedFonts: [String] = []

  private static let chooseOtherTag = "__choose_other__"

  /// Every fixed-pitch font actually installed — including any Nerd Fonts — not a
  /// curated shortlist. Filtered to monospaced since a terminal needs a fixed grid.
  private static func loadMonospacedFonts() -> [String] {
    NSFontManager.shared.availableFonts
      .filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
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
        Picker("Open in", selection: $terminalAppPath) {
          ForEach(terminalApps, id: \.path) { url in
            Text(url.deletingPathExtension().lastPathComponent).tag(url.path)
          }
          Divider()
          Text("Other…").tag(Self.chooseOtherTag)
        }
        .onChange(of: terminalAppPath) { oldValue, newValue in
          guard newValue == Self.chooseOtherTag else { return }
          chooseTerminalApp(fallback: oldValue)
        }

        Picker("Font", selection: $fontName) {
          ForEach(availableFonts, id: \.self) { name in
            Text(name).font(.custom(name, size: 13)).tag(name)
          }
        }
        .onChange(of: fontName) { NotificationCenter.default.post(name: .terminalFontChanged, object: nil) }

        Stepper(value: $fontSize, in: 8...24, step: 1) {
          Text("Font size: \(Int(fontSize)) pt")
        }
        .onChange(of: fontSize) { NotificationCenter.default.post(name: .terminalFontChanged, object: nil) }

        Text("The in-app terminal uses this font; changes apply to open sessions immediately.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task {
      loadTerminalApps()
      if monospacedFonts.isEmpty { monospacedFonts = Self.loadMonospacedFonts() }
    }
  }

  private func loadTerminalApps() {
    let bundleIDs = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                     "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty",
                     "com.github.wez.wezterm"]
    var urls = bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    let current = URL(fileURLWithPath: terminalAppPath)
    if !urls.contains(where: { $0.path == current.path }), FileManager.default.fileExists(atPath: current.path) {
      urls.append(current)
    }
    terminalApps = urls
  }

  private func chooseTerminalApp(fallback: String) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Choose"
    if panel.runModal() == .OK, let url = panel.url {
      terminalAppPath = url.path
      loadTerminalApps()
    } else {
      terminalAppPath = fallback
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
        switch testResult {
        case .success(let name):
          Label(name, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failure(let message):
          Label(message, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
            .lineLimit(2)
        case nil:
          EmptyView()
        }
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
