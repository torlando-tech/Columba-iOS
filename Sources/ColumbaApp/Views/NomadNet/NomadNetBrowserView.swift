import SwiftUI
import ReticulumSwift

/// Main browser view for browsing NomadNet node pages.
@available(iOS 17.0, macOS 14.0, *)
struct NomadNetBrowserView: View {
    @State private var viewModel: NomadNetBrowserViewModel

    init(nodeHash: Data, nodeName: String?, transport: ReticulumTransport, pathTable: PathTable, identity: Identity) {
        _viewModel = State(initialValue: NomadNetBrowserViewModel(
            nodeHash: nodeHash,
            nodeName: nodeName,
            transport: transport,
            pathTable: pathTable,
            identity: identity
        ))
    }

    var body: some View {
        ZStack {
            // Page background color
            pageBackground
                .ignoresSafeArea()

            if let document = viewModel.currentDocument {
                ScrollView {
                    MicronDocumentView(document: document) { link in
                        Task { await viewModel.handleLinkTap(link) }
                    }
                }
            } else if !viewModel.isLoading {
                ContentUnavailableView(
                    "No Page Loaded",
                    systemImage: "globe",
                    description: Text(viewModel.errorMessage ?? "")
                )
            }

            // Loading overlay
            if viewModel.isLoading {
                loadingOverlay
            }
        }
        .navigationTitle(viewModel.currentNodeName ?? "Node Browser")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                urlBar
            }

            ToolbarItem(placement: .navigationBarLeading) {
                if viewModel.canGoBack {
                    Button {
                        Task { await viewModel.goBack() }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button {
                        Task { await viewModel.identifyToNode() }
                    } label: {
                        Label("Identify to Node", systemImage: "person.badge.key")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await viewModel.loadPage()
        }
        .task(id: viewModel.isLoading) {
            if viewModel.isLoading {
                await viewModel.pollStatus()
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("Retry") {
                Task { await viewModel.loadPage() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Subviews

    private var urlBar: some View {
        Text(viewModel.displayURL)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 220)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(viewModel.statusMessage.isEmpty ? "Loading..." : viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var pageBackground: some View {
        if let bgHex = viewModel.currentDocument?.headers.backgroundColor,
           let color = MicronTextStyle.colorFrom3Hex(bgHex) {
            color
        } else {
            Color(.systemBackground)
        }
    }
}
