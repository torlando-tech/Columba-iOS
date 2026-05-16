#if COLUMBA_NOMADNET_ENABLED
import SwiftUI

/// Main browser view for browsing NomadNet node pages.
@available(iOS 17.0, macOS 14.0, *)
struct NomadNetBrowserView: View {
    @State private var viewModel: NomadNetBrowserViewModel

    init(nodeHash: Data, nodeName: String?, backend: PythonRNSBackend, identity: Identity) {
        _viewModel = State(initialValue: NomadNetBrowserViewModel(
            nodeHash: nodeHash,
            nodeName: nodeName,
            backend: backend,
            identity: identity
        ))
    }

    var body: some View {
        ZStack {
            // Page background color
            pageBackground
                .ignoresSafeArea()

            if let document = viewModel.currentDocument {
                MicronRenderContainer(
                    document: document,
                    mode: viewModel.renderingMode,
                    formFields: $viewModel.formFields,
                    checkboxFields: $viewModel.checkboxFields,
                    radioFields: $viewModel.radioFields,
                    partialDocuments: viewModel.partialDocuments,
                    loadingPartials: viewModel.loadingPartials
                ) { link in
                    Task { await viewModel.handleLinkTap(link) }
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

            #if os(iOS)
            ToolbarItem(placement: .navigationBarLeading) { backButton }
            ToolbarItem(placement: .navigationBarTrailing) { actionsMenu }
            #else
            ToolbarItem(placement: .navigation) { backButton }
            ToolbarItem(placement: .primaryAction) { actionsMenu }
            #endif
        }
        .task {
            await viewModel.loadPage()
        }
        .task(id: viewModel.isLoading) {
            if viewModel.isLoading {
                await viewModel.pollStatus()
            }
        }
        #if os(iOS)
        .sheet(isPresented: $viewModel.showingShareSheet) {
            if let url = viewModel.downloadedFileURL {
                ShareSheet(items: [url])
            }
        }
        #endif
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

    @ViewBuilder
    private var backButton: some View {
        if viewModel.canGoBack {
            Button {
                Task { await viewModel.goBack() }
            } label: {
                Image(systemName: "chevron.left")
            }
        }
    }

    private var actionsMenu: some View {
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

            Divider()

            Menu {
                ForEach(NomadNetRenderingMode.allCases, id: \.self) { mode in
                    Button {
                        viewModel.renderingMode = mode
                    } label: {
                        if viewModel.renderingMode == mode {
                            Label(mode.displayName, systemImage: "checkmark")
                        } else {
                            Text(mode.displayName)
                        }
                    }
                }
            } label: {
                Label("Rendering Mode", systemImage: viewModel.renderingMode.iconName)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
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
            Color.platformSystemBackground
        }
    }
}
#endif
