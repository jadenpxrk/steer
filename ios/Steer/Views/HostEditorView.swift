import NIOSSH
import SwiftUI

struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hostStore: HostStore

    @State private var host: Host
    @State private var password: String
    @State private var privateKey: String
    @State private var fallbackHostnames: String
    @State private var jumpID: UUID?
    @State private var errorMessage: String?
    @State private var credentialsLoaded: Bool
    private let isExisting: Bool

    init(host: Host? = nil) {
        let initialHost = host ?? Host(name: "", hostname: "", username: "", transport: .auto)
        let stored = initialHost.protectCredentials ? nil : try? KeychainStore.credentials(for: initialHost.id)
        _host = State(initialValue: initialHost)
        _password = State(initialValue: stored?.password ?? "")
        _privateKey = State(initialValue: stored?.privateKey ?? "")
        _fallbackHostnames = State(initialValue: initialHost.fallbackHostnames.joined(separator: "\n"))
        _jumpID = State(initialValue: initialHost.jump?.id)
        _credentialsLoaded = State(initialValue: !initialHost.protectCredentials)
        isExisting = host != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name", text: $host.name)
                    TextField("Hostname", text: $host.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("User", text: $host.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $host.port, format: .number)
                        .keyboardType(.numberPad)
                    TextField("Fallback addresses", text: $fallbackHostnames, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Optional. One hostname or IP per line; tried in order when the primary address cannot connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Connection type") {
                    Picker("Connection type", selection: $host.transport) {
                        ForEach(HostTransport.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(transportNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if host.transport == .mosh {
                        TextField("UDP port range", text: $host.moshPorts, prompt: Text("UDP port range, e.g. 60000:60010"))
                            .keyboardType(.numbersAndPunctuation)
                        TextField("mosh-server path", text: $host.moshServerPath, prompt: Text("mosh-server path"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Leave these blank unless the host needs them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if host.transport == .et {
                        TextField("TCP port", value: $host.etPort, format: .number.grouping(.never), prompt: Text("TCP port (2022)"))
                            .keyboardType(.numberPad)
                    }
                }

                if host.transport == .ssh {
                    Section("Jump host") {
                        Picker("Connect through", selection: $jumpID) {
                            Text("None").tag(UUID?.none)
                            ForEach(hostStore.hosts.filter { $0.id != host.id && $0.jump == nil }) { candidate in
                                Text(candidate.displayName).tag(UUID?.some(candidate.id))
                            }
                        }
                        .disabled(!hostStore.dependents(of: host.id).isEmpty)
                        Text(hostStore.dependents(of: host.id).isEmpty
                             ? "Optional. Reach this host through another saved host, like ssh -J. Each host keeps its own credentials and verified key."
                             : "Other hosts connect through this host. Only one jump level is supported, so it cannot have a jump host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("Forward SSH agent", isOn: $host.forwardAgent)
                            .tint(.green)
                        Text("Like ssh -A: while connected, programs on this host can use its saved key to sign in elsewhere (git, ssh). Only enable for hosts you trust.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Startup") {
                    TextField("Command", text: $host.startupCommand)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Optional. Sent after login (e.g. herdr). Leave empty for a normal shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Agent companion") {
                    Toggle("Use host companion", isOn: $host.companionEnabled)
                        .tint(.green)
                    Text("Optional. Install and start the Steer companion on this host for structured conversations and Claude approvals. Setup is in companion/README.md.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Keychain credentials") {
                    Toggle("Require Face ID or device passcode", isOn: $host.protectCredentials)
                        .tint(.green)
                        .disabled(isExisting && !credentialsLoaded)
                    if !credentialsLoaded {
                        Button("Unlock saved credentials", systemImage: "faceid") {
                            unlockCredentials()
                        }
                    }
                    SecureField("Password (optional)", text: $password)
                        .disabled(!credentialsLoaded)
                    TextEditor(text: $privateKey)
                        .accessibilityIdentifier("private-key")
                        .frame(minHeight: 100)
                        .font(.system(.caption, design: .monospaced))
                        .overlay(alignment: .topLeading) {
                            if privateKey.isEmpty {
                                Text("OpenSSH private key (optional)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .disabled(!credentialsLoaded)
                    if privateKey.isEmpty {
                        Button("Generate Ed25519 Key", systemImage: "key") {
                            privateKey = (try? OpenSSHKeyGenerator.makeEd25519(comment: "steer").privateKey) ?? ""
                        }
                        .disabled(!credentialsLoaded)
                    } else if let command = authorizeCommand {
                        ShareLink(item: command) {
                            Label("Share Authorize Command", systemImage: "square.and.arrow.up")
                        }
                        Text("Run this once on the host to allow this key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("OpenSSH Ed25519, ECDSA, and RSA keys without a passphrase are supported and tried before the password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Host")
            .navigationBarTitleDisplayMode(.inline)
            .steerChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            host.hostname.isEmpty
                                || host.username.isEmpty
                                || !(1...65_535).contains(host.port)
                                || !credentialsLoaded
                                || !(host.moshPorts.isEmpty || MoshConnect.portRange(host.moshPorts) != nil)
                                || !(host.etPort.map { (1...65_535).contains($0) } ?? true)
                        )
                }
            }
            .errorAlert("Could not save credentials", message: $errorMessage)
        }
        .interactiveDismissDisabled()
    }

    private var transportNote: String {
        switch host.transport {
        case .auto:
            "Tries Mosh, then Eternal Terminal, then SSH. Mosh and ET keep the terminal alive across network changes and sleep; SSH always handles sign-in, sessions, and tools."
        case .ssh:
            "A plain SSH terminal. Use it where UDP is blocked, mosh and etserver aren't installed, or you need a jump host or agent forwarding."
        case .mosh:
            "Mosh keeps the terminal alive across network changes and sleep over UDP. The host needs mosh-server (e.g. brew install mosh)."
        case .et:
            "Eternal Terminal keeps the terminal alive across network changes and sleep over TCP, so it works where UDP is blocked. The host needs etserver running (e.g. brew install et)."
        }
    }

    private var authorizeCommand: String? {
        guard let key = try? OpenSSHPrivateKeyParser.parse(privateKey) else { return nil }
        let line = String(openSSHPublicKey: key.publicKey)
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(line) steer' >> ~/.ssh/authorized_keys"
    }

    private func save() {
        do {
            host.fallbackHostnames = fallbackHostnames
                .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",")))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.caseInsensitiveCompare(host.hostname) != .orderedSame }
            // Jump hosts and agent forwarding are SSH-channel features.
            if host.transport != .ssh {
                jumpID = nil
                host.forwardAgent = false
            }
            host.moshPorts = host.moshPorts.trimmingCharacters(in: .whitespaces)
            host.moshServerPath = host.moshServerPath.trimmingCharacters(in: .whitespaces)
            if !hostStore.dependents(of: host.id).isEmpty { jumpID = nil }
            host.jump = jumpID.flatMap { id in hostStore.hosts.first { $0.id == id } }.map(JumpHost.init)
            try KeychainStore.save(
                password: password,
                privateKey: privateKey,
                for: host.id,
                requiresUserPresence: host.protectCredentials
            )
            hostStore.save(host)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlockCredentials() {
        do {
            let stored = try KeychainStore.credentials(
                for: host.id,
                prompt: "Unlock credentials for \(host.displayName)"
            )
            password = stored.password
            privateKey = stored.privateKey
            credentialsLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
