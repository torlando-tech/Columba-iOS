//
//  OnboardingView.swift
//  ColumbaApp
//
//  Top-level 5-page onboarding flow container.
//  Manual navigation only (no swipe), with page indicator dots and skip button.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct OnboardingView: View {
    let identityManager: IdentityManager
    let settingsRepository: SettingsRepository
    /// True when the flow is being shown to an existing user from
    /// Settings → Advanced — `OnboardingViewModel.completeOnboarding`
    /// skips identity / interface / display-name creation in that
    /// mode so we don't duplicate the user's data.
    var isRestart: Bool = false
    let onComplete: () -> Void

    @State private var viewModel = OnboardingViewModel()
    @State private var showRestoreSheet = false
    @State private var migrationVM: MigrationViewModel?

    var body: some View {
        ZStack {
            Theme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Propagate the isRestart flag to the view model
                // exactly once. Doing it here (vs. in init) keeps
                // `@State` initialization clean.
                Color.clear.frame(height: 0).onAppear {
                    if isRestart && !viewModel.isRestart {
                        viewModel.isRestart = true
                    }
                }
                // Skip button (pages 0-3)
                HStack {
                    Spacer()
                    if viewModel.currentPage < OnboardingViewModel.pageCount - 1 {
                        Button {
                            Task {
                                try? await viewModel.skipOnboarding(
                                    identityManager: identityManager,
                                    settingsRepository: settingsRepository
                                )
                                onComplete()
                            }
                        } label: {
                            Text("Skip")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 8)

                // Page content
                Group {
                    switch viewModel.currentPage {
                    case 0:
                        WelcomePage(
                            onContinue: { viewModel.nextPage() },
                            onRestoreFile: { data in
                                let vm = MigrationViewModel(
                                    identityManager: identityManager,
                                    settingsRepository: settingsRepository
                                )
                                migrationVM = vm
                                showRestoreSheet = true
                                Task { await vm.handleImportFile(data: data) }
                            }
                        )
                    case 1:
                        IdentityPage(
                            displayName: $viewModel.displayName,
                            onBack: { viewModel.previousPage() },
                            onContinue: { viewModel.nextPage() }
                        )
                    case 2:
                        ConnectivityPage(
                            selectedInterfaces: $viewModel.selectedInterfaces,
                            selectedTcpServer: $viewModel.selectedTcpServer,
                            onBack: { viewModel.previousPage() },
                            onContinue: { viewModel.nextPage() }
                        )
                    #if ENABLE_NETWORK_EXTENSION
                    case 3:
                        BackgroundTransportPage(
                            enabled: $viewModel.backgroundTunnelEnabled,
                            onBack: { viewModel.previousPage() },
                            onContinue: { viewModel.nextPage() }
                        )
                    case 4:
                        permissionsPageView()
                    case 5:
                        completePageView()
                    #else
                    case 3:
                        permissionsPageView()
                    case 4:
                        completePageView()
                    #endif
                    default:
                        EmptyView()
                    }
                }

                // Page indicator dots
                HStack(spacing: 8) {
                    ForEach(0..<OnboardingViewModel.pageCount, id: \.self) { index in
                        Circle()
                            .fill(index == viewModel.currentPage ? Theme.accentColor : Theme.textDisabled)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.currentPage)
        .task {
            await viewModel.checkNotificationStatus()
        }
        .sheet(isPresented: $showRestoreSheet) {
            if let vm = migrationVM {
                OnboardingRestoreSheet(viewModel: vm) {
                    showRestoreSheet = false
                    // Restore complete — skip onboarding and finish
                    Task {
                        try? await viewModel.skipOnboarding(
                            identityManager: identityManager,
                            settingsRepository: settingsRepository
                        )
                        onComplete()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func permissionsPageView() -> some View {
        PermissionsPage(
            notificationsGranted: viewModel.notificationsGranted,
            onRequestNotifications: {
                Task { await viewModel.requestNotificationPermission() }
            },
            onBack: { viewModel.previousPage() },
            onContinue: { viewModel.nextPage() }
        )
    }

    @ViewBuilder
    private func completePageView() -> some View {
        CompletePage(
            displayName: viewModel.effectiveDisplayName,
            interfaceNames: viewModel.selectedInterfaceNames,
            notificationsGranted: viewModel.notificationsGranted,
            isSaving: viewModel.isSaving,
            selectedRNode: viewModel.selectedInterfaces.contains(.rnode),
            identityManager: identityManager,
            qrCodeString: viewModel.qrCodeString,
            onPrepare: {
                await viewModel.prepareIdentity(identityManager: identityManager)
            },
            onFinish: {
                Task {
                    try? await viewModel.completeOnboarding(
                        identityManager: identityManager,
                        settingsRepository: settingsRepository
                    )
                    onComplete()
                }
            }
        )
    }
}
