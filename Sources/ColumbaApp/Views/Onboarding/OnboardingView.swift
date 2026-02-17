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
    let onComplete: () -> Void

    @State private var viewModel = OnboardingViewModel()

    var body: some View {
        ZStack {
            Theme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
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
                            onContinue: { viewModel.nextPage() }
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
                    case 3:
                        PermissionsPage(
                            notificationsGranted: viewModel.notificationsGranted,
                            onRequestNotifications: {
                                Task { await viewModel.requestNotificationPermission() }
                            },
                            onBack: { viewModel.previousPage() },
                            onContinue: { viewModel.nextPage() }
                        )
                    case 4:
                        CompletePage(
                            displayName: viewModel.effectiveDisplayName,
                            interfaceNames: viewModel.selectedInterfaceNames,
                            notificationsGranted: viewModel.notificationsGranted,
                            isSaving: viewModel.isSaving,
                            selectedRNode: viewModel.selectedInterfaces.contains(.rnode),
                            identityManager: identityManager,
                            onShowQR: { },
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
    }
}
