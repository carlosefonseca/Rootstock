import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      AzureSettingsView()
        .tabItem { Label("Azure DevOps", systemImage: "cloud") }
    }
    .frame(width: 540, height: 460)
  }
}

private struct AzureSettingsView: View {
  @Environment(WorkspaceModel.self) private var workspace
  @State private var orgs: [String] = []
  @State private var azAvailable: Bool?
  @State private var newOrg = ""
  @AppStorage("azure.defaultWorkItemOrg") private var defaultWorkItemOrg = ""
  @AppStorage("azure.defaultWorkItemProject") private var defaultWorkItemProject = ""

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
          TextField("Add organization (e.g. CASDevOps)", text: $newOrg)
            .textFieldStyle(.roundedBorder)
            .onSubmit(addOrg)
          Button("Add") { addOrg() }.disabled(newOrg.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }

      Section("Work items") {
        TextField("Default work-item org", text: $defaultWorkItemOrg, prompt: Text("CASDevOps"))
        TextField("Default work-item project", text: $defaultWorkItemProject, prompt: Text("CA Entrega"))
        Text("Used for work-item lookups when a repo's .dcdp/config.toml doesn't set WORKITEM_ORG. Work items often live in a different org than code.")
          .font(.caption).foregroundStyle(.secondary)
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
      if let org = DcdpConfig.load(worktree: clone.rootURL)?.workItemOrg { set.insert(org) }
    }
    if let org = AzureSettingsStore.defaultWorkItemOrg { set.insert(org) }
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
    .task(id: org) { hasStored = Keychain.pat(org: org) != nil }
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
