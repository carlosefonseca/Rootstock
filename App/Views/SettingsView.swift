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
          Text("Track a clone to discover its Azure DevOps organization.")
            .font(.callout).foregroundStyle(.secondary)
        } else {
          ForEach(orgs, id: \.self) { org in
            OrgPATRow(org: org)
          }
        }
      }
    }
    .formStyle(.grouped)
    .task {
      orgs = discoverOrgs()
      azAvailable = await AzureAuth.shared.hasAzSession()
    }
  }

  private func discoverOrgs() -> [String] {
    var set = Set<String>()
    for clone in workspace.clones {
      if let remote = AzureRemote.parse(clone.remoteURL) { set.insert(remote.org) }
      if let org = DcdpConfig.load(worktree: clone.rootURL)?.workItemOrg { set.insert(org) }
    }
    return set.sorted()
  }
}

private struct OrgPATRow: View {
  var org: String

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
