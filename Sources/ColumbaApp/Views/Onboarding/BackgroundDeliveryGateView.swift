// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC

//
//  BackgroundDeliveryGateView.swift
//  ColumbaApp
//
//  First-launch gate for Model B (Network Extension). The NE owns the Reticulum/
//  LXMF node, so the app cannot send or receive until its on-device VPN tunnel is
//  installed + running. iOS requires an explicit user approval for a VPN
//  configuration, so we present this deliberate step (instead of silently triggering
//  the system prompt behind a spinner). Shown by RootView while
//  AppServices.needsBackgroundDeliveryApproval is true; tapping Enable installs +
//  starts the tunnel and, once it connects, resumes app initialization.
//

#if COLUMBA_RUNTIME_MODEL_B
import SwiftUI

struct BackgroundDeliveryGateView: View {
    let appServices: AppServices

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Theme.accentColor.opacity(0.15))
                        .frame(width: 110, height: 110)
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Theme.accentColor)
                }

                VStack(spacing: 10) {
                    Text("Enable Background Delivery")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("iOS uses its VPN system to let Columba's network component continue running when the app is not open. Only traffic from Columba and Reticulum uses this component; your other apps and web traffic are not routed through Columba.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, 24)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()

                Button {
                    enable()
                } label: {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        Text(isWorking ? "Connecting…" : (errorMessage == nil ? "Enable" : "Try Again"))
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge))
                }
                .disabled(isWorking)
                .padding(.horizontal, 24)

                Text("iOS will ask you to allow the configuration and will show a VPN indicator while Background Delivery is enabled. Delivery still depends on available Reticulum connections.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
    }

    private func enable() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            let ok = await appServices.approveBackgroundDelivery()
            isWorking = false
            if !ok {
                errorMessage = "Couldn't enable background delivery. Make sure you tapped “Allow” on the VPN prompt, then try again."
            }
            // On success, AppServices clears `needsBackgroundDeliveryApproval` and
            // resumes init — RootView swaps this gate out automatically.
        }
    }
}
#endif
