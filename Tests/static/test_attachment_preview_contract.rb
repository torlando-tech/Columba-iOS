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
    assert_includes messaging, 'onDismiss: attachmentPreviewStore.dismiss'
    assert_includes messaging, 'attachmentPreviewStore.exitConversation()'
  end
end
