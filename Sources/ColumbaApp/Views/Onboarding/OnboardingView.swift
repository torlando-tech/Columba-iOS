#if COLUMBA_ONBOARDING_ENABLED
//
//  OnboardingView.swift
//  ColumbaApp
//
//  Top-level onboarding flow container (six Model B pages, five otherwise).
//  Manual navigation only (no swipe), with page indicator dots and skip button.
//

import SwiftUI
import RNSAPI

@available(iOS 17.0, macOS 14.0, *)
struct OnboardingView: View {
    let identityManager: IdentityManager
    let settingsRepository: SettingsRepository
    let appServices: AppServices
    let onComplete: () -> Void
    let onCancel: (() -> Void)?

    @State private var viewModel: OnboardingViewModel
    @State private var skipErrorMessage: String?
    #if COLUMBA_MIGRATION_ENABLED
    @State private var restoreSession: RestoreSession?
    #endif

    init(
        identityManager: IdentityManager,
        settingsRepository: SettingsRepository,
        appServices: AppServices,
        existingIdentity: LocalIdentity? = nil,
        onCancel: (() -> Void)? = nil,
        onComplete: @escaping () -> Void
    ) {
        self.identityManager = identityManager
        self.settingsRepository = settingsRepository
        self.appServices = appServices
        self.onCancel = onCancel
        self.onComplete = onComplete
        _viewModel = State(initialValue: OnboardingViewModel(existingIdentity: existingIdentity))
    }

    var body: some View {
        ZStack {
            Theme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // First-run setup offers explicit safe defaults. Settings review mode
                // instead offers a mutation-free Close action on every page.
                HStack {
                    Spacer()
                    if let onCancel {
                        Button("Close", action: onCancel)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .disabled(viewModel.isSaving)
                    } else if viewModel.currentPage < 4 {
                        Button {
                            guard !viewModel.isSaving else { return }
                            Task {
                                do {
                                    try await viewModel.skipOnboarding(
                                        identityManager: identityManager,
                                        settingsRepository: settingsRepository
                                    )
                                    onComplete()
                                } catch {
                                    skipErrorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            Text("Use Defaults")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .disabled(viewModel.isSaving)
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 8)

                // Page content
                Group {
                    switch viewModel.currentPage {
                    case 0:
                        #if COLUMBA_MIGRATION_ENABLED
                        if viewModel.isReviewingExistingSetup {
                            WelcomePage(onContinue: { viewModel.nextPage() })
                        } else {
                            WelcomePage(
                                onContinue: { viewModel.nextPage() },
                                onRestoreFile: { data in
                                    let vm = MigrationViewModel(
                                        identityManager: identityManager,
                                        settingsRepository: settingsRepository
                                    )
                                    restoreSession = RestoreSession(viewModel: vm)
                                    Task { await vm.handleImportFile(data: data) }
                                }
                            )
                        }
                        #else
                        WelcomePage(onContinue: { viewModel.nextPage() })
                        #endif
                    case 1:
                        IdentityPage(
                            displayName: $viewModel.displayName,
                            isReadOnly: viewModel.isReviewingExistingSetup,
                            onBack: { viewModel.previousPage() },
                            onContinue: { viewModel.nextPage() }
                        )
                    case 2:
                        ConnectivityPage(
                            selectedInterfaces: $viewModel.selectedInterfaces,
                            selectedTcpServer: $viewModel.selectedTcpServer,
                            isReadOnly: viewModel.isReviewingExistingSetup,
                            onRequestBluetooth: { viewModel.requestBluetoothPermission() },
                            onBack: { viewModel.previousPage() },
                            onContinue: { viewModel.nextPage() }
                        )
                    case 3:
                        PermissionsPage(
                            notificationsGranted: viewModel.notificationsGranted,
                            isReadOnly: viewModel.isReviewingExistingSetup,
                            onRequestNotifications: {
                                Task { await viewModel.requestNotificationPermission() }
                            },
                            bluetoothGranted: viewModel.bluetoothGranted,
                            onRequestBluetooth: { viewModel.requestBluetoothPermission() },
                            onBack: { viewModel.previousPage() },
                            onContinue: { viewModel.nextPage() }
                        )
                    #if COLUMBA_RUNTIME_MODEL_B
                    case 4:
                        BackgroundDeliveryPage(
                            isReadOnly: viewModel.isReviewingExistingSetup,
                            onEnable: {
                                if viewModel.isReviewingExistingSetup {
                                    viewModel.nextPage()
                                    return true
                                }
                                // Create the identity now (idempotent) so the NE can
                                // load it from the shared keychain, activate it, then
                                // bring the tunnel up. Only advance on success.
                                await viewModel.prepareIdentity(identityManager: identityManager)
                                guard let local = viewModel.createdIdentity,
                                      let result = try? await identityManager.switchToIdentity(local.identityHash)
                                else { return false }
                                // Seed the TCP relay into the shared store BEFORE the NE
                                // is started below — the in-NE node reads its relay once
                                // at start and won't pick up a later write, so seeding
                                // after would leave it with no TCP path.
                                viewModel.seedInterfaces()
                                let ok = await appServices.enableBackgroundDeliveryForOnboarding(identity: result.1)
                                if ok { viewModel.nextPage() }
                                return ok
                            },
                            onBack: { viewModel.previousPage() }
                        )
                    case 5:
                        completePage
                    #else
                    case 4:
                        completePage
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
                .accessibilityLabel("Step \(viewModel.currentPage + 1) of \(OnboardingViewModel.pageCount)")
                Text("Step \(viewModel.currentPage + 1) of \(OnboardingViewModel.pageCount)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDisabled)
                    .padding(.top, 6)
                .padding(.bottom, 12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.currentPage)
        .alert(
            "Unable to Skip Setup",
            isPresented: Binding(
                get: { skipErrorMessage != nil },
                set: { if !$0 { skipErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                skipErrorMessage = nil
            }
        } message: {
            Text(skipErrorMessage ?? "Please try again.")
        }
        .task {
            await viewModel.checkNotificationStatus()
            viewModel.checkBluetoothStatus()
        }
        #if COLUMBA_MIGRATION_ENABLED
        .sheet(item: $restoreSession) { session in
            OnboardingRestoreSheet(viewModel: session.viewModel) { result in
                try await viewModel.completeRestoredOnboarding(
                    preferredIdentityHash: result.preferredIdentityHash,
                    identityManager: identityManager,
                    settingsRepository: settingsRepository
                )
                restoreSession = nil
                onComplete()
            }
        }
        #endif
    }

    #if COLUMBA_MIGRATION_ENABLED
    private struct RestoreSession: Identifiable {
        let id = UUID()
        let viewModel: MigrationViewModel
    }
    #endif

    private var completePage: some View {
        CompletePage(
            displayName: viewModel.effectiveDisplayName,
            interfaceNames: viewModel.selectedInterfaceNames,
            notificationsGranted: viewModel.notificationsGranted,
            isReviewOnly: viewModel.isReviewingExistingSetup,
            isSaving: viewModel.isSaving,
            selectedRNode: viewModel.selectedInterfaces.contains(.rnode),
            identityManager: identityManager,
            qrCodeString: viewModel.qrCodeString,
            onPrepare: {
                await viewModel.prepareIdentity(identityManager: identityManager)
            },
            onFinish: {
                if viewModel.isReviewingExistingSetup {
                    onCancel?()
                    return
                }
                Task {
                    do {
                        try await viewModel.completeOnboarding(
                            identityManager: identityManager,
                            settingsRepository: settingsRepository
                        )
                        onComplete()
                    } catch {
                        skipErrorMessage = error.localizedDescription
                    }
                }
            }
        )
    }
}
#endif
