import SwiftUI
import FleetarrKit

enum InstanceEditMode {
    case add
    case edit(FleetInstance)
}

/// Add/edit form for an instance (spec §4): label, service type, base URL, credential, self-signed
/// override, plus a "Test Connection" action that reports the real failure reason before saving.
struct InstanceEditView: View {
    @Environment(FleetStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let mode: InstanceEditMode

    @State private var serviceType: ServiceType = .sonarr
    @State private var label = ""
    @State private var baseURLString = ""
    @State private var secret = ""
    @State private var allowInsecureTLS = false
    @State private var isEnabled = true
    @State private var isHidden = false

    @State private var existingID: UUID?
    @State private var existingSortOrder = 0
    @State private var hasStoredSecret = false

    @State private var testing = false
    @State private var testResult: ConnectionTestResult?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    Picker("Type", selection: $serviceType) {
                        ForEach(ServiceType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField("Label", text: $label, prompt: Text(serviceType.displayName))
                }

                Section {
                    TextField("https://host:port/path", text: $baseURLString)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                    SecureField(secretFieldPrompt, text: $secret)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    if usesPlainHTTP {
                        Label("Credentials will travel unencrypted over HTTP", systemImage: "lock.open")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Toggle("Allow self-signed certificate", isOn: $allowInsecureTLS)
                } header: {
                    Text("Connection")
                } footer: {
                    if isEditing && hasStoredSecret {
                        Text("Leave the credential blank to keep the one already stored.")
                    }
                }

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                    Toggle("Hide from dashboard", isOn: $isHidden)
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "bolt.horizontal")
                            if testing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(testing || !canTest)

                    if let testResult {
                        TestResultRow(result: testResult)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Instance" : "Add Instance")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .onAppear(perform: loadInitial)
        }
    }

    // MARK: Derived

    private var secretFieldPrompt: String {
        switch serviceType.credentialKind {
        case .apiKey: "API key"
        case .plexOAuthToken: "Plex token"
        }
    }

    private var usesPlainHTTP: Bool {
        URL(string: baseURLString.trimmingCharacters(in: .whitespaces))?.scheme?.lowercased() == "http"
    }

    private var draft: FleetInstance? {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else { return nil }
        let instance = FleetInstance(
            id: existingID ?? UUID(),
            serviceType: serviceType,
            label: label.trimmingCharacters(in: .whitespaces).isEmpty
                ? serviceType.displayName
                : label.trimmingCharacters(in: .whitespaces),
            baseURLString: trimmedURL,
            allowInsecureTLS: allowInsecureTLS,
            isEnabled: isEnabled,
            isHiddenFromDashboard: isHidden,
            sortOrder: existingSortOrder
        )
        return instance.baseURL == nil ? nil : instance
    }

    private var canSave: Bool { draft != nil }
    private var canTest: Bool { draft != nil && !secret.isEmpty }

    // MARK: Actions

    private func loadInitial() {
        guard case let .edit(instance) = mode else { return }
        serviceType = instance.serviceType
        label = instance.label
        baseURLString = instance.baseURLString
        allowInsecureTLS = instance.allowInsecureTLS
        isEnabled = instance.isEnabled
        isHidden = instance.isHiddenFromDashboard
        existingID = instance.id
        existingSortOrder = instance.sortOrder
        hasStoredSecret = store.hasStoredSecret(for: instance)
    }

    private func runTest() async {
        guard let instance = draft else { return }
        testing = true
        defer { testing = false }
        testResult = await store.testConnection(instance, secret: secret)
    }

    private func save() {
        guard let instance = draft else { return }
        store.save(instance, secret: secret.isEmpty ? nil : secret)
        dismiss()
    }
}

private struct TestResultRow: View {
    let result: ConnectionTestResult

    var body: some View {
        Label {
            Text(result.message)
                .font(.callout)
        } icon: {
            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(result.isSuccess ? .green : .red)
        }
        .accessibilityElement(children: .combine)
    }
}
