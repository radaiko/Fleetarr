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
    @Environment(\.openURL) private var openURL

    let mode: InstanceEditMode

    @State private var serviceType: ServiceType = .sonarr
    @State private var label = ""
    @State private var baseURLString = ""
    @State private var secret = ""
    @State private var allowInsecureTLS = false
    @State private var isEnabled = true
    @State private var isHidden = false
    @State private var headers: [HeaderField] = []
    @State private var ignorePatterns: [PatternField] = []

    @State private var existingID: UUID?
    @State private var existingSortOrder = 0
    @State private var hasStoredSecret = false

    @State private var testing = false
    @State private var testResult: ConnectionTestResult?

    @State private var plexSigningIn = false
    @State private var plexStatus: String?

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

                if serviceType == .plex {
                    Section {
                        Button {
                            Task { await signInWithPlex() }
                        } label: {
                            HStack {
                                Label("Sign in with Plex", systemImage: "person.badge.key")
                                if plexSigningIn {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(plexSigningIn)
                        if let plexStatus {
                            Text(plexStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Plex account")
                    } footer: {
                        Text("Opens plex.tv to sign in; the token is filled in for you. You can also "
                             + "paste a token above manually.")
                    }
                }

                Section {
                    ForEach($headers) { $header in
                        HStack(spacing: 8) {
                            TextField("Header", text: $header.key)
                                .frame(maxWidth: 130, alignment: .leading)
                            Divider()
                            TextField("Value", text: $header.value)
                        }
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    }
                    .onDelete { headers.remove(atOffsets: $0) }
                    Button { headers.append(HeaderField()) } label: {
                        Label("Add header", systemImage: "plus")
                    }
                } header: {
                    Text("Custom headers")
                } footer: {
                    Text("Static headers sent with every request — e.g. HTTP Basic auth or a header "
                         + "your reverse proxy requires. Don't put the service API key here.")
                }

                if serviceType == .sabnzbd {
                    Section {
                        ForEach($ignorePatterns) { $pattern in
                            TextField("Warning text to ignore", text: $pattern.text)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                #endif
                        }
                        .onDelete { ignorePatterns.remove(atOffsets: $0) }
                        Button { ignorePatterns.append(PatternField()) } label: {
                            Label("Add pattern", systemImage: "plus")
                        }
                    } header: {
                        Text("Cosmetic ignore list")
                    } footer: {
                        Text("Case-insensitive text; SABnzbd warnings containing any of these won't "
                             + "count toward the problem badge. The built-in \"non-writable "
                             + "special-character filename\" warning is always ignored.")
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
        let headerDict = Dictionary(
            headers.compactMap { row -> (String, String)? in
                let key = row.key.trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : (key, row.value)
            },
            uniquingKeysWith: { _, last in last }
        )
        let patterns = ignorePatterns
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let instance = FleetInstance(
            id: existingID ?? UUID(),
            serviceType: serviceType,
            label: label.trimmingCharacters(in: .whitespaces).isEmpty
                ? serviceType.displayName
                : label.trimmingCharacters(in: .whitespaces),
            baseURLString: trimmedURL,
            allowInsecureTLS: allowInsecureTLS,
            extraHeaders: headerDict,
            cosmeticIgnorePatterns: serviceType == .sabnzbd ? patterns : [],
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
        headers = instance.extraHeaders
            .sorted { $0.key < $1.key }
            .map { HeaderField(key: $0.key, value: $0.value) }
        ignorePatterns = instance.cosmeticIgnorePatterns.map { PatternField(text: $0) }
    }

    /// Credentials pasted from a web dashboard often carry a trailing newline/space, which servers
    /// reject with a 401 — trim it so the same key that works in curl works here too.
    private var trimmedSecret: String {
        secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runTest() async {
        guard let instance = draft else { return }
        testing = true
        defer { testing = false }
        testResult = await store.testConnection(instance, secret: trimmedSecret)
    }

    private func save() {
        guard let instance = draft else { return }
        store.save(instance, secret: trimmedSecret.isEmpty ? nil : trimmedSecret)
        dismiss()
    }

    // MARK: Plex sign-in (spec §6.5)

    /// A stable per-install Plex client identifier, generated once.
    private var plexClientIdentifier: String {
        let key = "plexClientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let identifier = UUID().uuidString
        UserDefaults.standard.set(identifier, forKey: key)
        return identifier
    }

    private func signInWithPlex() async {
        plexSigningIn = true
        plexStatus = "Requesting sign-in…"
        defer { plexSigningIn = false }

        let auth = PlexAuthClient(clientIdentifier: plexClientIdentifier)
        do {
            let pin = try await auth.requestPin()
            if let url = auth.authURL(for: pin) {
                openURL(url)
            }
            plexStatus = "Waiting for you to sign in to Plex…"
            // Poll up to ~90s for the token.
            for _ in 0..<45 {
                try await Task.sleep(for: .seconds(2))
                if let token = try await auth.fetchToken(pinID: pin.id) {
                    secret = token
                    plexStatus = "Signed in — token filled in."
                    return
                }
            }
            plexStatus = "Timed out waiting for sign-in. Try again."
        } catch is CancellationError {
            plexStatus = nil
        } catch {
            plexStatus = "Sign-in failed: \((error as? FleetError)?.userMessage ?? "please try again")."
        }
    }
}

/// An editable custom-header row (spec §4). Identity is stable across edits so SwiftUI keeps focus.
private struct HeaderField: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String
    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id; self.key = key; self.value = value
    }
}

/// An editable SABnzbd cosmetic-ignore pattern row (spec §6.4).
private struct PatternField: Identifiable, Equatable {
    let id: UUID
    var text: String
    init(id: UUID = UUID(), text: String = "") { self.id = id; self.text = text }
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
