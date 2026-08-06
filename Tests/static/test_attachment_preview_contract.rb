#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
PROJECT = Xcodeproj::Project.open(File.join(ROOT, 'Columba.xcodeproj'))

class AttachmentPreviewContractTests < Minitest::Test
  PREVIEW_SOURCE = 'Sources/ColumbaApp/Views/Messaging/MessageAttachmentPreviewItem.swift'
  PREVIEW_TEST = 'Tests/ColumbaAppTests/MessageAttachmentPreviewTests.swift'

  def source_paths(target_name)
    target = PROJECT.targets.find { |candidate| candidate.name == target_name }
    refute_nil target
    target.source_build_phase.files.map do |build_file|
      build_file.file_ref.real_path.relative_path_from(Pathname.new(ROOT)).to_s
    end
  end

  def test_preview_boundary_is_shared_and_regressions_are_hosted
    assert_includes source_paths('ColumbaApp'), PREVIEW_SOURCE
    assert_includes source_paths('ColumbaModelBApp'), PREVIEW_SOURCE
    assert_includes source_paths('ColumbaAppTests'), PREVIEW_TEST
  end

  def test_preview_boundary_uses_private_item_directory_and_byte_type_detection
    source = File.read(File.join(ROOT, PREVIEW_SOURCE))
    assert_includes source, 'temporaryDirectory'
    assert_includes source, 'UUID'
    assert_includes source, '.atomic'
    assert_includes source, 'CGImageSourceGetType'
    assert_includes source, 'removeItem(at: directoryURL)'
    assert_includes source, 'final class MessageAttachmentPreviewStore'
    assert_includes source, 'item?.cleanup()'
  end

  def test_representable_update_and_screen_lifecycle_use_attachment_owners
    timeline = File.read(File.join(ROOT, 'Sources/ColumbaApp/Views/Messaging/MessageTimelineView.swift'))
    update = timeline.split('func updateUIViewController', 2).fetch(1)
                     .split('func applyAttachmentCallbacks', 2).fetch(0)
    assert_includes update, 'applyAttachmentCallbacks(to: controller)'

    messaging = File.read(File.join(ROOT, 'Sources/ColumbaApp/Views/Messaging/MessagingView.swift'))
    assert_includes messaging, '@StateObject private var attachmentPreviewStore'
    assert_includes messaging, '.quickLookPreview(attachmentPreviewURLBinding)'
    assert_includes messaging, 'attachmentPreviewStore.exitConversation()'
    refute_includes messaging, 'QLPreviewController'
    refute_includes messaging, 'ShareLink(item: item.url)'
    assert_operator messaging.scan('onOpenImage:').length, :>=, 2
    assert_operator messaging.scan('onOpenFileAttachment:').length, :>=, 2

    bubble = File.read(File.join(ROOT, 'Sources/ColumbaApp/Views/Messaging/MessageBubble.swift'))
    assert_includes bubble, '.accessibilityIdentifier("bubble_file_chip")'
    assert_includes bubble, '.accessibilityIdentifier("bubble_file_chip_\(index)")'
  end

  def test_attachment_controls_use_native_buttons_and_owner_arbitrates_reactions
    bubble = File.read(File.join(ROOT, 'Sources/ColumbaApp/Views/Messaging/MessageBubble.swift'))
    assert_operator bubble.scan('.buttonStyle(.plain)').length, :>=, 3
    assert_includes bubble, '.simultaneousGesture('
    assert_includes bubble, 'LongPressGesture(minimumDuration: 0.4)'
    refute_includes bubble, 'PrimitiveButtonStyle'
    refute_includes bubble, '.exclusively(before: TapGesture())'

    preview = File.read(File.join(ROOT, PREVIEW_SOURCE))
    assert_includes preview, 'beginReactionMode()'
    assert_includes preview, 'endReactionMode()'
    assert_includes preview, 'guard !isReactionModeActive'

    messaging = File.read(File.join(ROOT, 'Sources/ColumbaApp/Views/Messaging/MessagingView.swift'))
    assert_operator messaging.scan('attachmentPreviewStore.beginReactionMode()').length, :>=, 2
    assert_includes messaging, 'attachmentPreviewStore.endReactionMode()'
  end
end
