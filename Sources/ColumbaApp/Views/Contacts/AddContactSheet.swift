//
//  AddContactSheet.swift
//  Columba-iOS
//
//  Confirmation sheet shown after scanning a QR code or opening an lxma:// deep link.
//  Displays the scanned contact info and allows setting a nickname before adding.
//

import SwiftUI

/// Data from a scanned QR code or deep link, used as sheet binding item.
struct ScannedContact: Identifiable {
    let id = UUID()
    let destinationHash: Data
    let publicKey: Data

    var hashHex: String {
        destinationHash.map { String(format: "%02x", $0) }.joined()
    }
}

/// Confirmation sheet for adding a contact from QR scan or deep link.
@available(iOS 17.0, macOS 14.0, *)
struct AddContactSheet: View {
    let scannedContact: ScannedContact
    let viewModel: ContactsViewModel
    let onDismiss: () -> Void

    @State private var nickname: String = ""
    @State private var isAdding = false
    @State private var alreadyExists = false

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
            .alert("Contact Already Added", isPresented: $alreadyExists) {
                Button("OK") { onDismiss() }
            } message: {
                Text("This contact is already in your contacts list.")
            }
        }
    }

    private func addContact() {
        if viewModel.contactExists(scannedContact.destinationHash) {
            alreadyExists = true
            return
        }

        isAdding = true
        Task {
            let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            await viewModel.addContactFromQR(
                destinationHash: scannedContact.destinationHash,
                publicKey: scannedContact.publicKey,
                nickname: name.isEmpty ? nil : name
            )
            isAdding = false
            onDismiss()
        }
    }
}
