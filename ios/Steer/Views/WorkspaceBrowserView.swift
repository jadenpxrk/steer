import SwiftUI

struct WorkspaceBrowserItem: Equatable, Identifiable {
    let controllerID: UUID
    let host: Host
    let listing: MuxListing

    var id: String { "\(host.id.uuidString):\(listing.id)" }

    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let text = [listing.title, host.displayName, host.hostname,
                    listing.attach.herdrSessionName ?? "", brand.name,
                    listing.tabs.map(\.title).joined(separator: " ")].joined(separator: " ")
        return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }

    var brand: (name: String, asset: String) {
        switch listing.attach {
        case .herdrAgent, .herdrSession: ("Herdr", "HerdrLogo")
        case .tmux: ("tmux", "TmuxLogo")
        case .zellij: ("Zellij", "ZellijLogo")
        }
    }
}

/// Workspace tiles, loading state, and per-host issues derived from live controllers.
@MainActor
struct WorkspaceBrowserState {
    var items: [WorkspaceBrowserItem] = []
    var isLoading = false
    var issues: [String] = []

    init(_ controllers: [TerminalController]) {
        for controller in controllers {
            let host = controller.host
            let catalog = controller.mux.catalog
            items += (catalog?.listings ?? []).map {
                WorkspaceBrowserItem(controllerID: controller.id, host: host, listing: $0)
            }
            if controller.phase == .connecting || controller.mux.isLoading {
                isLoading = true
            } else if let unavailable = catalog?.unavailableSessions, !unavailable.isEmpty {
                issues.append("\(host.displayName): couldn't load \(unavailable.joined(separator: ", ")). Pull to refresh.")
            }
        }
    }
}

struct WorkspaceBrowserView: View {
    let controllers: [TerminalController]
    let query: String
    let open: (Host, MuxRow) -> Void

    var body: some View {
        let model = WorkspaceBrowserState(controllers)
        let items = model.items.filter { $0.matches(query) }
        VStack(spacing: 0) {
            if !model.issues.isEmpty {
                Text(model.issues.joined(separator: "\n"))
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(12)
            }
            if items.isEmpty {
                Group {
                    if model.isLoading, query.isEmpty {
                        ProgressView().accessibilityLabel("Looking for workspaces")
                    } else {
                        Text(query.isEmpty ? "No workspaces yet" : "No matching workspaces")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            tile(item)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 12)
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    @ViewBuilder
    private func tile(_ item: WorkspaceBrowserItem) -> some View {
        if let controller = controllers.first(where: { $0.id == item.controllerID }) {
            WorkspaceTile(item: item, controller: controller) { open(item.host, item.listing.attach) }
        }
    }
}

private struct WorkspaceTile: View {
    let item: WorkspaceBrowserItem
    var controller: TerminalController
    let open: () -> Void

    private var snapshot: TerminalPreviewSnapshot? {
        controller.mux.previews[item.listing.attach.id]
            ?? item.listing.tabs.lazy.compactMap { controller.mux.previews[$0.attach.id] }.first
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if let snapshot, !snapshot.bytes.isEmpty {
                            TerminalSnapshotView(snapshot: snapshot).allowsHitTesting(false)
                        } else if controller.mux.previewLoadingIDs.contains(item.listing.attach.id) {
                            ProgressView().accessibilityLabel("Loading preview")
                        } else {
                            Text("Open workspace")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(alignment: .center, spacing: 6) {
                    Image(item.brand.asset)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Theme.ink)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text(item.listing.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                }
                Text(item.host.displayName)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.listing.title), \(item.host.displayName), \(item.brand.name)")
        .accessibilityHint("Open workspace")
        .accessibilityIdentifier("workspace-\(item.id)")
    }
}
