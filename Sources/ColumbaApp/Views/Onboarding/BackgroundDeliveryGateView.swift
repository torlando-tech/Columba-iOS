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

#if ENABLE_NETWORK_EXTENSION
import SwiftUI

struct BackgroundDeliveryGateView: View {
    @Bindable var appServices: AppServices

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

                    Text("Columba runs a small on-device VPN so it can keep delivering and receiving your messages in the background — even when the app is closed. Your traffic isn't sent to any server; the tunnel only powers Columba's own network node on your device.")
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

                Text("iOS will ask you to allow the VPN configuration. Columba can't deliver messages in the background without it.")
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
