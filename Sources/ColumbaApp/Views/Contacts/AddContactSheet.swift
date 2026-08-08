//
//  AddContactSheet.swift
//  Columba-iOS
//
//  Confirmation sheet shown after scanning a QR code or opening an lxma:// deep link.
//  Displays the scanned contact info and allows setting a nickname before adding.
//

import SwiftUI
import RNSAPI

/// Data from a scanned QR code or deep link, used as sheet binding item.
struct ScannedContact: Identifiable {
    let id = UUID()
    let destinationHash: Data
    let publicKey: Data

    var hashHex: String {
        destinationHash.map { String(format: "%02x", $0) }.joined()
    }
}

enum ExistingContactNotice: String, Identifiable {
    case alreadyAdded
    case identityUpdated

    var id: String { rawValue }
}

/// Confirmation sheet for adding a contact from QR scan or deep link.
@available(iOS 17.0, macOS 14.0, *)
struct AddContactSheet: View {
    let scannedContact: ScannedContact
    let viewModel: ContactsViewModel
    let onDismiss: () -> Void
    let onExistingContact: (ExistingContactNotice) -> Void

    @State private var nickname: String = ""
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Identicon
                SettingsIdenticonView(hash: scannedContact.hashHex)
                    .frame(width: 80, height: 80)
                    .padding(.top, 24)

                // Destination hash
                VStack(spacing: 4) {
                    Text("Destination Hash")
                        .font(.caption)
                        .foregroundStyle(.gray)

                    Text(scannedContact.hashHex)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                // Nickname field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nickname (optional)")
                        .font(.caption)
                        .foregroundStyle(.gray)

                    TextField("Enter a nickname", text: $nickname)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Theme.backgroundTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                }
                .padding(.horizontal, 24)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.error)
                        .padding(.horizontal, 24)
                }

                Spacer()

                // Buttons
                VStack(spacing: 12) {
                    Button {
                        addContact()
                    } label: {
                        HStack(spacing: 8) {
                            if isAdding {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                            }
                            Text("Add Contact")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isAdding)

                    Button("Cancel") {
                        onDismiss()
                    }
                    .font(.system(size: 17))
                    .foregroundStyle(.gray)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .background(Theme.backgroundSecondary)
            .navigationTitle("Add Contact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled(isAdding)
        }
    }

    private func addContact() {
        let existed = viewModel.contactExists(scannedContact.destinationHash)
        isAdding = true
        Task {
            let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = await viewModel.addContactFromQR(
                destinationHash: scannedContact.destinationHash,
                publicKey: scannedContact.publicKey,
                nickname: name.isEmpty ? nil : name
            )
            isAdding = false
            guard succeeded else { return }
            if existed {
                onExistingContact(.identityUpdated)
            } else {
                onDismiss()
            }
        }
    }
}

/// Native manual-entry flow matching Android's add-contact affordance.
/// Hash-only contacts are persisted passively; identity/path lookup remains
/// owned by the existing send-time resolution gate.
@available(iOS 17.0, macOS 14.0, *)
struct ManualContactEntrySheet: View {
    let viewModel: ContactsViewModel
    let onDismiss: () -> Void
    let onExistingContact: (ExistingContactNotice) -> Void

    @State private var address = ""
    @State private var nickname = ""
    @State private var validationError: String?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("lxma://… or 32-character hash", text: $address, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .accessibilityLabel("Identity or Address")
                        .onChange(of: address) { _, _ in
                            validationError = nil
                        }

                    TextField("Nickname (optional)", text: $nickname)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                } header: {
                    Text("Contact Address")
                } footer: {
                    Text("Enter a complete lxma:// identity or a 32-character LXMF destination hash. A hash-only contact is resolved when you send a message.")
                }

                if let message = validationError {
                    Section {
                        Text(message)
                            .foregroundStyle(Theme.error)
                            .accessibilityIdentifier("manual_contact_error")
                    }
                }
            }
            .navigationTitle("Add Contact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addContact()
                    }
                    .disabled(isAdding || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(isAdding)
        }
    }

    private func addContact() {
        guard let parsed = ContactsViewModel.parseContactInput(address) else {
            validationError = "Enter a valid lxma:// identity or 32-character hexadecimal destination hash."
            return
        }

        let existed = viewModel.contactExists(parsed.destinationHash)
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        isAdding = true

        Task {
            let succeeded: Bool
            if let publicKey = parsed.publicKey {
                succeeded = await viewModel.addContactFromQR(
                    destinationHash: parsed.destinationHash,
                    publicKey: publicKey,
                    nickname: trimmedNickname.isEmpty ? nil : trimmedNickname
                )
            } else {
                succeeded = await viewModel.addContactFromHash(
                    destinationHash: parsed.destinationHash,
                    nickname: trimmedNickname.isEmpty ? nil : trimmedNickname
                )
            }

            isAdding = false
            guard succeeded else {
                validationError = viewModel.errorMessage ?? "The contact could not be added. Please try again."
                return
            }
            if existed {
                onExistingContact(parsed.publicKey == nil ? .alreadyAdded : .identityUpdated)
            } else {
                onDismiss()
            }
        }
    }
}
