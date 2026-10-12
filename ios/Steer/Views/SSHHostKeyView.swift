import SwiftUI

struct SSHHostKeyView: View {
    let request: SSHHostKeyStore.Request
    let resolve: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Name", value: request.host.displayName)
                    LabeledContent("Address", value: "\(request.host.hostname):\(request.host.port)")
                }
                Section("SSH fingerprint") {
                    Text(request.fingerprint)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Text("Compare this fingerprint with the server's SSH host key before trusting this connection. Steer will remember it and block unexpected changes.")
                }
                Section {
                    Button("Trust and Connect") { resolve(true) }
                    Button("Cancel", role: .cancel) { resolve(false) }
                }
            }
            .navigationTitle("Verify Server")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}
