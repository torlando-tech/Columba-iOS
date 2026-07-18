#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'xcodeproj'

REPOSITORY_ROOT = File.expand_path('../..', __dir__)
PROJECT_PATH = File.join(REPOSITORY_ROOT, 'Columba.xcodeproj')
SCRIPT_PATH = File.join(REPOSITORY_ROOT, 'support/isolate-modelb-targets.rb')
CANONICAL_FLAGS = %w[
  COLUMBA_RUNTIME_PYTHON
  COLUMBA_RUNTIME_MODEL_B
  ENABLE_NETWORK_EXTENSION
  COLUMBA_BACKEND_SWIFT
].freeze
ONBOARDING_FLAG = 'COLUMBA_ONBOARDING_ENABLED'

class ModelBTargetIsolationTests < Minitest::Test
  def setup
    @project = Xcodeproj::Project.open(PROJECT_PATH)
    @shipping = unique_target('ColumbaApp')
    @shipping_tests = unique_target('ColumbaAppTests')
    @model_b = unique_target('ColumbaModelBApp')
    @extension = unique_target('ColumbaNetworkExtension')
  end

  def unique_target(name)
    matches = @project.targets.select { |target| target.name == name }
    assert_equal 1, matches.size, "expected exactly one #{name} target"
    matches.first
  end

  def extension_embed_phase?(phase)
    phase.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) &&
      (phase.name == 'Embed App Extensions' || phase.symbol_dst_subfolder_spec == :plug_ins)
  end

  def phase_signature(phase)
    [phase.class.name, phase.respond_to?(:name) ? phase.name : nil,
     phase.respond_to?(:dst_subfolder_spec) ? phase.dst_subfolder_spec : nil]
  end

  def build_file_signature(build_file)
    reference = build_file.product_ref || build_file.file_ref
    [build_file.product_ref ? :product : :file, reference&.display_name,
     build_file.settings, build_file.platform_filter, build_file.platform_filters]
  end

  def canonical_tokens(configuration)
    compilation_tokens(configuration) & CANONICAL_FLAGS
  end

  def compilation_tokens(configuration)
    Array(configuration.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'])
      .flat_map { |value| value.to_s.split }
  end

  def test_both_application_targets_exist_and_are_ios_apps
    assert_equal 'com.apple.product-type.application', @shipping.product_type
    assert_equal 'com.apple.product-type.application', @model_b.product_type
    assert_equal 'ColumbaModelBApp.app', @model_b.product_reference.path
  end

  def test_shipping_has_no_extension_dependency_or_embed
    refute @shipping.dependencies.any? { |dependency| dependency.target == @extension }
    refute @shipping.build_phases.any? { |phase| extension_embed_phase?(phase) }
    refute(@shipping.build_phases.flat_map(&:files).any? do |build_file|
      build_file.file_ref == @extension.product_reference
    end)
  end

  def test_model_b_has_exactly_one_extension_dependency_and_embed
    assert_equal 1, @model_b.dependencies.count { |dependency| dependency.target == @extension }
    phases = @model_b.build_phases.select { |phase| extension_embed_phase?(phase) }
    assert_equal 1, phases.size
    assert_equal :plug_ins, phases.first.symbol_dst_subfolder_spec
    embeds = phases.first.files.select do |build_file|
      build_file.file_ref == @extension.product_reference
    end
    assert_equal 1, embeds.size
    assert_includes embeds.first.settings.fetch('ATTRIBUTES'), 'CodeSignOnCopy'
  end

  def test_initial_app_phase_and_package_membership_is_cloned
    shipping_phases = @shipping.build_phases.reject { |phase| extension_embed_phase?(phase) }
    model_phases = @model_b.build_phases.reject { |phase| extension_embed_phase?(phase) }
    assert_equal shipping_phases.map { |phase| phase_signature(phase) },
                 model_phases.map { |phase| phase_signature(phase) }

    shipping_phases.zip(model_phases).each do |shipping_phase, model_phase|
      assert_equal shipping_phase.files.map { |file| build_file_signature(file) },
                   model_phase.files.map { |file| build_file_signature(file) },
                   "phase membership differs for #{phase_signature(shipping_phase)}"
    end

    assert_equal @shipping.package_product_dependencies.map(&:product_name),
                 @model_b.package_product_dependencies.map(&:product_name)
    @shipping.package_product_dependencies.zip(@model_b.package_product_dependencies).each do |left, right|
      refute_same left, right
      assert_same left.package, right.package
    end
  end

  def test_configuration_flags_entitlements_and_identity_are_isolated
    assert_equal @shipping.build_configurations.map(&:name), @model_b.build_configurations.map(&:name)
    identity_keys = %w[
      PRODUCT_BUNDLE_IDENTIFIER DEVELOPMENT_TEAM CODE_SIGN_IDENTITY
      CODE_SIGN_STYLE PROVISIONING_PROFILE PROVISIONING_PROFILE_SPECIFIER
      INFOPLIST_FILE PRODUCT_MODULE_NAME
    ]

    @shipping.build_configurations.zip(@model_b.build_configurations).each do |shipping, model_b|
      assert_equal ['COLUMBA_RUNTIME_PYTHON'], canonical_tokens(shipping), shipping.name
      refute_includes compilation_tokens(shipping), ONBOARDING_FLAG,
                      "shipping app retained Model B onboarding in #{shipping.name}"
      assert_equal %w[COLUMBA_RUNTIME_MODEL_B ENABLE_NETWORK_EXTENSION COLUMBA_BACKEND_SWIFT],
                   canonical_tokens(model_b), model_b.name
      if model_b.name.end_with?('-Swift')
        assert_includes compilation_tokens(model_b), ONBOARDING_FLAG,
                        "Model B lost inherited onboarding in #{model_b.name}"
      else
        refute_includes compilation_tokens(model_b), ONBOARDING_FLAG,
                        "Model B gained onboarding in #{model_b.name}"
      end
      assert_equal 'Sources/ColumbaApp/Resources/ColumbaApp.entitlements',
                   shipping.build_settings['CODE_SIGN_ENTITLEMENTS']
      assert_equal 'Sources/ColumbaApp/Resources/ColumbaModelBApp.entitlements',
                   model_b.build_settings['CODE_SIGN_ENTITLEMENTS']
      identity_keys.each do |key|
        expected = shipping.build_settings[key]
        if expected.nil?
          assert_nil model_b.build_settings[key], "#{key} differs in #{shipping.name}"
        else
          assert_equal expected, model_b.build_settings[key],
                       "#{key} differs in #{shipping.name}"
        end
      end
    end
  end

  def test_shipping_test_configurations_match_their_host_runtime_flavor
    shipping_by_name = @shipping.build_configurations.to_h do |configuration|
      [configuration.name, configuration]
    end

    assert @shipping_tests.dependencies.any? { |dependency| dependency.target == @shipping },
           'ColumbaAppTests no longer depends on ColumbaApp'
    @shipping_tests.build_configurations.each do |test_configuration|
      host_configuration = shipping_by_name.fetch(test_configuration.name)
      assert_equal canonical_tokens(host_configuration), canonical_tokens(test_configuration),
                   "host/test runtime flavor differs in #{test_configuration.name}"
      assert_equal ['COLUMBA_RUNTIME_PYTHON'], canonical_tokens(test_configuration),
                   test_configuration.name
      refute_includes compilation_tokens(test_configuration), ONBOARDING_FLAG,
                      "shipping tests retained Model B onboarding in #{test_configuration.name}"
      assert_match(/ColumbaApp\.app/, test_configuration.build_settings.fetch('TEST_HOST'),
                   "TEST_HOST changed in #{test_configuration.name}")
      assert_equal '$(TEST_HOST)', test_configuration.build_settings.fetch('BUNDLE_LOADER'),
                   "BUNDLE_LOADER changed in #{test_configuration.name}"
    end
  end

  def test_app_targets_do_not_reuse_build_files_and_relations_are_unique
    shipping_ids = @shipping.build_phases.flat_map(&:files).map(&:uuid)
    model_ids = @model_b.build_phases.flat_map(&:files).map(&:uuid)
    assert_empty shipping_ids & model_ids

    phase_owners = Hash.new { |hash, key| hash[key] = [] }
    @project.targets.each do |target|
      dependency_targets = target.dependencies.map { |dependency| dependency.target&.uuid }
      assert_equal dependency_targets.uniq, dependency_targets, "duplicate dependency on #{target.name}"
      assert_equal target.build_phases.map(&:uuid).uniq, target.build_phases.map(&:uuid)
      target.build_phases.each do |phase|
        phase_owners[phase.uuid] << target.name
        ids = phase.files.map(&:uuid)
        assert_equal ids.uniq, ids, "duplicate build file in #{target.name}"
      end
    end
    assert phase_owners.values.all?(&:one?), 'a build phase is attached to multiple targets'
  end

  def test_reconciler_detaches_shared_shipping_phase_and_build_file_without_mutating_shipping
    Dir.mktmpdir('columba-modelb-shared-ownership') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)

      fixture = Xcodeproj::Project.open(temporary_project)
      fixture_shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      fixture_model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      shipping_sources = fixture_shipping.source_build_phase
      model_b_sources = fixture_model_b.source_build_phase
      shared_build_file = shipping_sources.files.first
      fixture_model_b.build_phases << shipping_sources
      fixture.save

      # xcodeproj refuses to serialize a PBXBuildFile with two parents, so seed
      # that malformed relationship directly after serializing the shared phase.
      pbxproj_path = File.join(temporary_project, 'project.pbxproj')
      pbxproj = File.read(pbxproj_path)
      phase_header = "\t\t#{model_b_sources.uuid} /* Sources */ = {"
      phase_start = pbxproj.index(phase_header) or raise 'missing Model B Sources phase in fixture'
      files_start = pbxproj.index("\t\t\tfiles = (\n", phase_start) or raise 'missing Model B Sources files'
      insertion_point = files_start + "\t\t\tfiles = (\n".length
      shared_entry = "\t\t\t\t#{shared_build_file.uuid} /* malformed shared build file */,\n"
      pbxproj.insert(insertion_point, shared_entry)
      File.write(pbxproj_path, pbxproj)

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_shipping = mutated.targets.find { |target| target.name == 'ColumbaApp' }
      mutated_model_b = mutated.targets.find { |target| target.name == 'ColumbaModelBApp' }
      shipping_source_id = mutated_shipping.source_build_phase.uuid
      shared_build_file_id = mutated_shipping.source_build_phase.files.first.uuid
      assert_includes mutated_model_b.build_phases.map(&:uuid), shipping_source_id,
                      'shared phase mutation did not survive serialization'
      shared_file_survived = mutated_model_b.build_phases.any? do |phase|
        phase.uuid != shipping_source_id && phase.files.any? { |file| file.uuid == shared_build_file_id }
      end
      assert shared_file_survived, 'shared build-file mutation did not survive serialization'
      shipping_semantic = mutated_shipping.to_hash

      output, error, status = Open3.capture3(
        { 'COLUMBA_PROJECT_PATH' => temporary_project }, RbConfig.ruby, SCRIPT_PATH
      )
      assert status.success?, "ownership reconciliation failed:\n#{output}\n#{error}"

      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
      reconciled_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      assert_equal shipping_semantic, reconciled_shipping.to_hash,
                   'shipping target changed while detaching malformed Model B ownership'
      refute_includes reconciled_model_b.build_phases.map(&:uuid), shipping_source_id
      refute_includes reconciled_model_b.build_phases.flat_map(&:files).map(&:uuid), shared_build_file_id

      local_sources = reconciled_model_b.source_build_phase
      shipping_first = reconciled_shipping.source_build_phase.files.first
      local_first = local_sources.files.find { |file| file.file_ref == shipping_first.file_ref }
      refute_nil local_first
      refute_equal shipping_first.uuid, local_first.uuid

      phase_owners = Hash.new { |hash, key| hash[key] = [] }
      build_file_owners = Hash.new { |hash, key| hash[key] = [] }
      reconciled.targets.each do |target|
        target.build_phases.each { |phase| phase_owners[phase.uuid] << target.uuid }
      end
      reconciled.objects.each do |object|
        next unless object.respond_to?(:files)

        object.files.each { |file| build_file_owners[file.uuid] << object.uuid }
      end
      assert phase_owners.values.all?(&:one?), 'a phase still has multiple target owners'
      assert build_file_owners.values.all?(&:one?), 'a build file still has multiple phase owners'
    end
  end

  def test_reconciler_removes_duplicate_target_product_dependencies_and_attributes
    Dir.mktmpdir('columba-modelb-duplicate-target') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)

      fixture = Xcodeproj::Project.open(temporary_project)
      retained = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      duplicate = fixture.new_target(:application, 'ColumbaModelBApp', :ios, nil)
      duplicate_id = duplicate.uuid
      duplicate_product_id = duplicate.product_reference.uuid
      fixture.root_object.attributes['TargetAttributes'][duplicate_id] = { 'CreatedOnToolsVersion' => 'stale' }
      retained.add_dependency(duplicate)
      fixture.save

      mutated = Xcodeproj::Project.open(temporary_project)
      assert_equal 2, mutated.targets.count { |target| target.name == 'ColumbaModelBApp' }
      duplicate_products = mutated.products_group.children.count do |reference|
        reference.path == 'ColumbaModelBApp.app'
      end
      assert_equal 2, duplicate_products
      assert mutated.root_object.attributes['TargetAttributes'].key?(duplicate_id)

      output, error, status = Open3.capture3(
        { 'COLUMBA_PROJECT_PATH' => temporary_project }, RbConfig.ruby, SCRIPT_PATH
      )
      assert status.success?, "duplicate-target reconciliation failed:\n#{output}\n#{error}"

      reconciled = Xcodeproj::Project.open(temporary_project)
      model_b_targets = reconciled.targets.select { |target| target.name == 'ColumbaModelBApp' }
      assert_equal 1, model_b_targets.size
      products = reconciled.products_group.children.select do |reference|
        reference.path == 'ColumbaModelBApp.app'
      end
      assert_equal [model_b_targets.first.product_reference.uuid], products.map(&:uuid)
      refute reconciled.objects_by_uuid.key?(duplicate_id)
      refute reconciled.objects_by_uuid.key?(duplicate_product_id)
      attributes = reconciled.root_object.attributes.fetch('TargetAttributes', {})
      assert_empty attributes.keys - reconciled.targets.map(&:uuid)
      stale_proxy = reconciled.objects.any? do |object|
        object.is_a?(Xcodeproj::Project::Object::PBXContainerItemProxy) &&
          object.remote_global_id_string == duplicate_id
      end
      refute stale_proxy
    end
  end

  def test_reconciler_repairs_dependency_mutations_preserves_extension_and_is_byte_idempotent
    Dir.mktmpdir('columba-modelb-isolation') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)

      fixture = Xcodeproj::Project.open(temporary_project)
      fixture_model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      fixture_shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      fixture_shipping_tests = fixture.targets.find { |target| target.name == 'ColumbaAppTests' }
      fixture_extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      [fixture_shipping, fixture_shipping_tests].each do |target|
        configuration = target.build_configurations.find { |candidate| candidate.name == 'Debug-Swift' }
        tokens = compilation_tokens(configuration)
        configuration.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
          (tokens + [ONBOARDING_FLAG, 'GENUINE_SHIPPING_CONDITION']).uniq.join(' ')
      end
      fixture_model_b.add_dependency(fixture_shipping)
      duplicate_proxy = fixture.new(Xcodeproj::Project::Object::PBXContainerItemProxy)
      duplicate_proxy.container_portal = fixture.root_object.uuid
      duplicate_proxy.proxy_type = Xcodeproj::Constants::PROXY_TYPES[:native_target]
      duplicate_proxy.remote_global_id_string = fixture_extension.uuid
      duplicate_proxy.remote_info = fixture_extension.name
      duplicate_dependency = fixture.new(Xcodeproj::Project::Object::PBXTargetDependency)
      duplicate_dependency.name = fixture_extension.name
      duplicate_dependency.target = fixture_extension
      duplicate_dependency.target_proxy = duplicate_proxy
      fixture_model_b.dependencies << duplicate_dependency
      assert fixture_model_b.dependencies.any? { |dependency| dependency.target == fixture_shipping },
             'mutation fixture lacks a stale Model B dependency'
      assert_operator fixture_model_b.dependencies.count { |dependency| dependency.target == fixture_extension },
                      :>=, 2, 'xcodeproj did not permit a duplicate extension dependency'
      fixture.save

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_model_b = mutated.targets.find { |target| target.name == 'ColumbaModelBApp' }
      assert_operator mutated_model_b.dependencies.size, :>=, 3,
                      'dependency mutations did not survive project serialization'
      before = mutated.targets.find { |target| target.name == 'ColumbaNetworkExtension' }.to_hash

      first_output, first_error, first_status = Open3.capture3(
        { 'COLUMBA_PROJECT_PATH' => temporary_project }, RbConfig.ruby, SCRIPT_PATH
      )
      assert first_status.success?, "first reconciliation failed:\n#{first_output}\n#{first_error}"
      first_hash = Digest::SHA256.file(File.join(temporary_project, 'project.pbxproj')).hexdigest
      after_project = Xcodeproj::Project.open(temporary_project)
      reconciled_model_b = after_project.targets.find { |target| target.name == 'ColumbaModelBApp' }
      reconciled_shipping = after_project.targets.find { |target| target.name == 'ColumbaApp' }
      reconciled_shipping_tests = after_project.targets.find { |target| target.name == 'ColumbaAppTests' }
      reconciled_extension = after_project.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      [reconciled_shipping, reconciled_shipping_tests].each do |target|
        configuration = target.build_configurations.find { |candidate| candidate.name == 'Debug-Swift' }
        refute_includes compilation_tokens(configuration), ONBOARDING_FLAG
        assert_includes compilation_tokens(configuration), 'GENUINE_SHIPPING_CONDITION'
      end
      assert_includes compilation_tokens(
        reconciled_model_b.build_configurations.find { |candidate| candidate.name == 'Debug-Swift' }
      ), ONBOARDING_FLAG
      assert_equal [reconciled_extension.uuid],
                   reconciled_model_b.dependencies.map { |dependency| dependency.target&.uuid },
                   'Model B dependencies were not authoritatively reconciled'
      assert_equal before, reconciled_extension.to_hash,
                   'extension target changed during reconciliation'

      second_output, second_error, second_status = Open3.capture3(
        { 'COLUMBA_PROJECT_PATH' => temporary_project }, RbConfig.ruby, SCRIPT_PATH
      )
      assert second_status.success?, "second reconciliation failed:\n#{second_output}\n#{second_error}"
      second_hash = Digest::SHA256.file(File.join(temporary_project, 'project.pbxproj')).hexdigest
      assert_equal first_hash, second_hash, 'second reconciliation changed project.pbxproj bytes'
      Xcodeproj::Project.open(temporary_project)
    end
  end
end
