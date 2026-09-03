//
//  ChatsSegmentSelector.swift
//  ColumbaApp
//
//  The Text | Voice subtab split on the Chats screen (issue #167). Same shape
//  as the ContactsView tab picker (Picker + .pickerStyle(.segmented)). Kept in
//  its own file to keep ChatsView.body under the Swift type-checker budget.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct ChatsSegmentSelector: View {
    @Binding var selection: ChatsSegment

    var body: some View {
        Picker("Chats segment", selection: $selection) {
            Text("Text").tag(ChatsSegment.text)
                .accessibilityIdentifier("chats_segment_text")
            Text("Voice").tag(ChatsSegment.voice)
                .accessibilityIdentifier("chats_segment_voice")
        }
        .pickerStyle(.segmented)
    }
}
