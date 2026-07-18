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
MODEL_B_ONLY_SOURCE_PATHS = %w[
  Sources/RNSBackendProxy/ProxyRnsBackend.swift
  Sources/ColumbaApp/Services/TunnelManager.swift
  Sources/ColumbaApp/Services/ExtensionFrameReader.swift
  Sources/ColumbaApp/Services/ModelBBLEService.swift
  Sources/ColumbaApp/Views/Settings/BackgroundTransportView.swift
  Sources/ColumbaApp/Views/Components/BackgroundVPNExplainer.swift
  Sources/ColumbaApp/Views/Onboarding/BackgroundDeliveryGateView.swift
  Sources/ColumbaApp/Views/Onboarding/BackgroundDeliveryPage.swift
  Sources/Shared/AppGroupBridgeInterface.swift
  Sources/Shared/AppGroupBLEDriver.swift
  Sources/Shared/AppGroupBLESeamTransport.swift
  Sources/Shared/AppGroupBLEServer.swift
  Sources/Shared/BLEDriverSeam.swift
  Sources/Shared/ProxyIPC.swift
  Sources/Shared/OutboxQueue.swift
  Sources/ColumbaApp/Services/ModelBRNodeService.swift
  Sources/Shared/AppGroupRNodeSeamTransport.swift
  Sources/Shared/AppGroupRNodeSeamWire.swift
  Sources/Shared/AppGroupRNodeServer.swift
  Sources/Shared/RNodeSeam.swift
  Sources/Shared/PropagationSeam.swift
  Sources/ColumbaApp/Services/ModelBInboundReplay.swift
].freeze
MODEL_B_ONLY_SOURCE_METADATA = MODEL_B_ONLY_SOURCE_PATHS.to_h do |path|
  [path, { settings: nil, platform_filter: nil, platform_filters: nil }]
end
MODEL_B_ONLY_SOURCE_METADATA['Sources/ColumbaApp/Services/ModelBInboundReplay.swift'] = {
  settings: nil,
  platform_filter: 'ios',
  platform_filters: nil
}
MODEL_B_ONLY_SOURCE_METADATA.each_value(&:freeze)
MODEL_B_ONLY_SOURCE_METADATA.freeze
SHIPPING_REQUIRED_SOURCE_PATHS = %w[
  Sources/ColumbaApp/Services/MessageRepository.swift
  Sources/PythonBridge/PythonBridge.swift
  Sources/PythonBridge/PythonRuntime.swift
  Sources/RNSBackendPy/PythonRNSBackend.swift
  Sources/Shared/NomadNetFetch.swift
  Sources/Shared/SharedFrameQueue.swift
  Sources/Shared/ExtensionDiagLog.swift
].freeze

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

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def source_paths(target, root = REPOSITORY_ROOT)
    target.source_build_phase.files.map do |build_file|
      build_file.file_ref.real_path.relative_path_from(Pathname.new(root)).to_s
    end
  end

  def isolated_source_metadata(target, root = REPOSITORY_ROOT)
    target.source_build_phase.files.each_with_object({}) do |build_file, metadata|
      path = build_file.file_ref.real_path.relative_path_from(Pathname.new(root)).to_s
      next unless MODEL_B_ONLY_SOURCE_METADATA.key?(path)

      metadata[path] = {
        settings: build_file.settings,
        platform_filter: build_file.platform_filter,
        platform_filters: build_file.platform_filters
      }
    end
  end

  def target_graph_signature(target)
    {
      uuid: target.uuid,
      identity: [target.name, target.product_name, target.product_type],
      product: target.product_reference && [
        target.product_reference.uuid,
        target.product_reference.path,
        target.product_reference.name,
        target.product_reference.explicit_file_type,
        target.product_reference.source_tree
      ],
      phases: target.build_phases.map do |phase|
        {
          uuid: phase.uuid,
          isa: phase.isa,
          scalar_attributes: phase.class.simple_attributes.to_h do |attribute|
            [attribute.name, deep_copy(phase.public_send(attribute.name))]
          end,
          files: phase.files.map do |build_file|
            {
              uuid: build_file.uuid,
              file_ref: build_file.file_ref&.uuid,
              product_ref: build_file.product_ref&.uuid,
              settings: deep_copy(build_file.settings),
              platform_filter: build_file.platform_filter,
              platform_filters: deep_copy(build_file.platform_filters)
            }
          end
        }
      end,
      package_products: target.package_product_dependencies.map do |dependency|
        [dependency.uuid, dependency.product_name, dependency.package&.uuid]
      end,
      configurations: target.build_configurations.map do |configuration|
        [configuration.uuid, configuration.name, configuration.base_configuration_reference&.uuid,
         deep_copy(configuration.build_settings)]
      end,
      configuration_list: [
        target.build_configuration_list.uuid,
        target.build_configuration_list.default_configuration_name,
        target.build_configuration_list.default_configuration_is_visible
      ],
      dependencies: target.dependencies.map do |dependency|
        proxy = dependency.target_proxy
        [dependency.uuid, dependency.name, dependency.target&.uuid, proxy&.uuid,
         proxy&.container_portal.respond_to?(:uuid) ? proxy.container_portal.uuid : proxy&.container_portal.to_s,
         proxy&.proxy_type,
         proxy&.remote_global_id_string, proxy&.remote_info]
      end
    }
  end

  def run_reconciler(temporary_project, label)
    output, error, status = Open3.capture3(
      { 'COLUMBA_PROJECT_PATH' => temporary_project }, RbConfig.ruby, SCRIPT_PATH
    )
    assert status.success?, "#{label} reconciliation failed:\n#{output}\n#{error}"
  end

  def assert_second_run_byte_idempotent(temporary_project)
    pbxproj_path = File.join(temporary_project, 'project.pbxproj')
    first_hash = Digest::SHA256.file(pbxproj_path).hexdigest
    run_reconciler(temporary_project, 'second')
    second_hash = Digest::SHA256.file(pbxproj_path).hexdigest
    assert_equal first_hash, second_hash, 'second reconciliation changed project.pbxproj bytes'
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

  def test_application_membership_is_authoritatively_partitioned
    assert_equal 22, MODEL_B_ONLY_SOURCE_PATHS.size
    shipping_phases = @shipping.build_phases.reject { |phase| extension_embed_phase?(phase) }
    model_phases = @model_b.build_phases.reject { |phase| extension_embed_phase?(phase) }
    assert_equal shipping_phases.map { |phase| phase_signature(phase) },
                 model_phases.map { |phase| phase_signature(phase) }

    shipping_phases.zip(model_phases).each do |shipping_phase, model_phase|
      next if shipping_phase.is_a?(Xcodeproj::Project::Object::PBXSourcesBuildPhase) ||
              shipping_phase.is_a?(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)

      assert_equal shipping_phase.files.map { |file| build_file_signature(file) },
                   model_phase.files.map { |file| build_file_signature(file) },
                   "phase membership differs for #{phase_signature(shipping_phase)}"
    end

    shipping_sources = source_paths(@shipping)
    model_b_sources = source_paths(@model_b)
    assert_empty MODEL_B_ONLY_SOURCE_PATHS & shipping_sources
    assert_empty MODEL_B_ONLY_SOURCE_PATHS - model_b_sources
    assert_empty SHIPPING_REQUIRED_SOURCE_PATHS - shipping_sources
    assert_empty SHIPPING_REQUIRED_SOURCE_PATHS - model_b_sources
    assert_equal shipping_sources + MODEL_B_ONLY_SOURCE_PATHS, model_b_sources
    assert_equal MODEL_B_ONLY_SOURCE_METADATA, isolated_source_metadata(@model_b)

    shipping_products = @shipping.package_product_dependencies.map(&:product_name)
    model_b_products = @model_b.package_product_dependencies.map(&:product_name)
    refute_includes shipping_products, 'ReticulumSwift'
    assert_includes model_b_products, 'ReticulumSwift'
    assert_includes shipping_products, 'LXMFSwift'
    assert_equal shipping_products + ['ReticulumSwift'], model_b_products
    @shipping.package_product_dependencies.each do |left|
      right = @model_b.package_product_dependencies.find do |candidate|
        candidate.product_name == left.product_name
      end
      refute_nil right
      refute_same left, right
      assert_same left.package, right.package
    end
  end

  def test_reconciler_repairs_shipping_source_and_reticulum_mutations
    Dir.mktmpdir('columba-modelb-source-package-mutation') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }

      excluded_refs = model_b.source_build_phase.files.filter_map do |file|
        path = file.file_ref.real_path.relative_path_from(Pathname.new(directory)).to_s
        [path, file.file_ref] if MODEL_B_ONLY_SOURCE_PATHS.include?(path)
      end.to_h
      assert_equal MODEL_B_ONLY_SOURCE_PATHS.sort, excluded_refs.keys.sort
      excluded_refs.each_value do |excluded_ref|
        seeded_source = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
        seeded_source.file_ref = excluded_ref
        shipping.source_build_phase.files << seeded_source
      end
      removed_model_b_path = 'Sources/ColumbaApp/Services/ModelBInboundReplay.swift'
      removed_model_b_file = model_b.source_build_phase.files.find do |file|
        file.file_ref.real_path.relative_path_from(Pathname.new(directory)).to_s == removed_model_b_path
      end
      refute_nil removed_model_b_file
      removed_model_b_file.remove_from_project

      stale_metadata_path = 'Sources/RNSBackendProxy/ProxyRnsBackend.swift'
      stale_metadata_file = model_b.source_build_phase.files.find do |file|
        file.file_ref.real_path.relative_path_from(Pathname.new(directory)).to_s == stale_metadata_path
      end
      refute_nil stale_metadata_file
      stale_metadata_file_id = stale_metadata_file.uuid
      stale_metadata_file.settings = { 'COMPILER_FLAGS' => '-DSTALE_MODEL_B_METADATA' }
      stale_metadata_file.platform_filter = 'macos'
      stale_metadata_file.platform_filters = %w[ios macos]

      model_reticulum = model_b.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      seeded_reticulum = fixture.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
      seeded_reticulum.product_name = 'ReticulumSwift'
      seeded_reticulum.package = model_reticulum.package
      shipping.package_product_dependencies << seeded_reticulum
      seeded_framework = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
      seeded_framework.product_ref = seeded_reticulum
      shipping.frameworks_build_phase.files << seeded_framework
      fixture.save

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_shipping = mutated.targets.find { |target| target.name == 'ColumbaApp' }
      mutated_model_b = mutated.targets.find { |target| target.name == 'ColumbaModelBApp' }
      mutated_shipping_sources = source_paths(mutated_shipping, File.dirname(temporary_project))
      assert_empty MODEL_B_ONLY_SOURCE_PATHS - mutated_shipping_sources
      refute_includes source_paths(mutated_model_b, File.dirname(temporary_project)), removed_model_b_path
      assert_equal 'macos', isolated_source_metadata(
        mutated_model_b, File.dirname(temporary_project)
      ).fetch(stale_metadata_path).fetch(:platform_filter)
      assert_includes mutated_shipping.package_product_dependencies.map(&:product_name), 'ReticulumSwift'
      extension_before = target_graph_signature(
        mutated.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      )

      run_reconciler(temporary_project, 'source-package-mutation')
      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
      reconciled_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      reconciled_extension = reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      reconciled_shipping_sources = source_paths(reconciled_shipping, File.dirname(temporary_project))
      reconciled_model_b_sources = source_paths(reconciled_model_b, File.dirname(temporary_project))
      assert_empty MODEL_B_ONLY_SOURCE_PATHS & reconciled_shipping_sources
      assert_equal reconciled_shipping_sources + MODEL_B_ONLY_SOURCE_PATHS, reconciled_model_b_sources
      assert_equal MODEL_B_ONLY_SOURCE_METADATA,
                   isolated_source_metadata(reconciled_model_b, File.dirname(temporary_project))
      retained_stale_file = reconciled_model_b.source_build_phase.files.find do |file|
        file.file_ref.real_path.relative_path_from(Pathname.new(directory)).to_s == stale_metadata_path
      end
      assert_equal stale_metadata_file_id, retained_stale_file&.uuid,
                   'reconciler replaced a target-local isolated-source build file'
      replay_build_file = reconciled_model_b.source_build_phase.files.find do |file|
        file.file_ref.real_path.relative_path_from(Pathname.new(directory)).to_s == removed_model_b_path
      end
      assert_equal 'ios', replay_build_file&.platform_filter
      refute_includes reconciled_shipping.package_product_dependencies.map(&:product_name), 'ReticulumSwift'
      refute(reconciled_shipping.frameworks_build_phase.files.any? do |file|
        file.product_ref&.product_name == 'ReticulumSwift'
      end)
      assert_equal extension_before, target_graph_signature(reconciled_extension)
      assert_second_run_byte_idempotent(temporary_project)
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

      run_reconciler(temporary_project, 'ownership')

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
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_reconciler_localizes_shipping_package_dependency_shared_with_model_b
    Dir.mktmpdir('columba-modelb-shared-shipping-package') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)

      fixture = Xcodeproj::Project.open(temporary_project)
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      shipping_dependency = shipping.package_product_dependencies.first
      local_dependency = model_b.package_product_dependencies.find do |dependency|
        dependency.product_name == shipping_dependency.product_name
      end
      local_build_file = model_b.frameworks_build_phase.files.find do |build_file|
        build_file.product_ref&.uuid == local_dependency.uuid
      end
      refute_nil local_build_file
      retained_dependencies = model_b.package_product_dependencies.to_a.reject do |dependency|
        dependency.uuid == local_dependency.uuid
      end
      model_b.package_product_dependencies.clear
      (retained_dependencies + [shipping_dependency]).each do |dependency|
        model_b.package_product_dependencies << dependency
      end
      fixture.save

      # Xcodeproj treats same-product dependencies as semantically equal and can
      # suppress this intentionally malformed cross-target productRef assignment.
      pbxproj_path = File.join(temporary_project, 'project.pbxproj')
      pbxproj = File.read(pbxproj_path)
      build_file_line = /^(\s*#{local_build_file.uuid}\b.*\bproductRef = )#{local_dependency.uuid}(\b.*)$/
      raise 'missing Model B package build file in fixture' unless pbxproj.sub!(
        build_file_line, "\\1#{shipping_dependency.uuid}\\2"
      )
      File.write(pbxproj_path, pbxproj)

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_shipping = mutated.targets.find { |target| target.name == 'ColumbaApp' }
      mutated_model_b = mutated.targets.find { |target| target.name == 'ColumbaModelBApp' }
      shared_id = mutated_shipping.package_product_dependencies.first.uuid
      assert_includes mutated_model_b.package_product_dependencies.map(&:uuid), shared_id
      assert(mutated_model_b.frameworks_build_phase.files.any? do |build_file|
        build_file.product_ref&.uuid == shared_id
      end)
      shipping_before = target_graph_signature(mutated_shipping)

      run_reconciler(temporary_project, 'shared-shipping-package')

      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
      reconciled_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      assert_equal shipping_before, target_graph_signature(reconciled_shipping),
                   'package reconciliation mutated the protected shipping graph'
      local = reconciled_model_b.package_product_dependencies.find do |dependency|
        dependency.product_name == reconciled_shipping.package_product_dependencies.first.product_name
      end
      refute_nil local
      refute_equal shared_id, local.uuid
      assert(reconciled_model_b.frameworks_build_phase.files.any? do |build_file|
        build_file.product_ref&.uuid == local.uuid
      end)
      owners = Hash.new { |hash, key| hash[key] = [] }
      reconciled.targets.each do |target|
        target.package_product_dependencies.each { |dependency| owners[dependency.uuid] << target.uuid }
      end
      assert owners.values.all?(&:one?), 'a package dependency still has multiple target owners'
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_reconciler_detaches_stale_package_shared_with_extension_without_mutating_extension
    Dir.mktmpdir('columba-modelb-shared-extension-package') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)

      fixture = Xcodeproj::Project.open(temporary_project)
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      package = fixture.targets.find { |target| target.name == 'ColumbaApp' }
                       .package_product_dependencies.first.package
      stale = fixture.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
      stale.product_name = 'AdversarialSharedStaleProduct'
      stale.package = package
      model_b.package_product_dependencies << stale
      extension.package_product_dependencies << stale
      model_b_file = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
      model_b_file.product_ref = stale
      model_b.frameworks_build_phase.files << model_b_file
      extension_file = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
      extension_file.product_ref = stale
      extension.frameworks_build_phase.files << extension_file
      stale_id = stale.uuid
      extension_file_id = extension_file.uuid
      fixture.save

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_extension = mutated.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      extension_before = target_graph_signature(mutated_extension)
      assert_equal stale_id, mutated_extension.frameworks_build_phase.files
                                        .find { |file| file.uuid == extension_file_id }.product_ref.uuid

      run_reconciler(temporary_project, 'shared-extension-package')

      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      reconciled_extension = reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      assert_equal extension_before, target_graph_signature(reconciled_extension),
                   'stale package cleanup mutated the protected extension graph'
      refute_includes reconciled_model_b.package_product_dependencies.map(&:uuid), stale_id
      refute(reconciled_model_b.build_phases.flat_map(&:files).any? do |build_file|
        build_file.product_ref&.uuid == stale_id
      end)
      protected_file = reconciled_extension.frameworks_build_phase.files.find do |file|
        file.uuid == extension_file_id
      end
      refute_nil protected_file
      assert_equal stale_id, protected_file.product_ref&.uuid
      assert reconciled.objects_by_uuid.key?(stale_id),
             'extension-owned package dependency was removed globally'
      assert_second_run_byte_idempotent(temporary_project)
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
      duplicate_package = fixture.new(
        Xcodeproj::Project::Object::XCSwiftPackageProductDependency
      )
      duplicate_package.product_name = 'DuplicateTargetOrphanProduct'
      duplicate_package.package = fixture.targets.find { |target| target.name == 'ColumbaApp' }
                                         .package_product_dependencies.first.package
      duplicate.package_product_dependencies << duplicate_package
      duplicate_package_file = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
      duplicate_package_file.product_ref = duplicate_package
      duplicate.frameworks_build_phase.files << duplicate_package_file
      duplicate_graph_ids = (
        duplicate.build_phases.flat_map { |phase| [phase.uuid] + phase.files.map(&:uuid) } +
        duplicate.build_configurations.map(&:uuid) +
        [duplicate.build_configuration_list.uuid, duplicate_package.uuid, duplicate_package_file.uuid]
      )
      fixture.root_object.attributes['TargetAttributes'][duplicate_id] = { 'CreatedOnToolsVersion' => 'stale' }
      retained.add_dependency(duplicate)
      fixture.save

      mutated = Xcodeproj::Project.open(temporary_project)
      assert_equal 2, mutated.targets.count { |target| target.name == 'ColumbaModelBApp' }
      mutated_duplicate = mutated.objects_by_uuid.fetch(duplicate_id)
      assert_includes mutated_duplicate.package_product_dependencies.map(&:uuid), duplicate_package.uuid
      assert_includes mutated_duplicate.build_phases.flat_map(&:files).map(&:uuid),
                      duplicate_package_file.uuid
      assert_equal duplicate_package.uuid,
                   mutated.objects_by_uuid.fetch(duplicate_package_file.uuid).product_ref&.uuid
      duplicate_products = mutated.products_group.children.count do |reference|
        reference.path == 'ColumbaModelBApp.app'
      end
      assert_equal 2, duplicate_products
      assert mutated.root_object.attributes['TargetAttributes'].key?(duplicate_id)

      run_reconciler(temporary_project, 'duplicate-target')

      reconciled = Xcodeproj::Project.open(temporary_project)
      model_b_targets = reconciled.targets.select { |target| target.name == 'ColumbaModelBApp' }
      assert_equal 1, model_b_targets.size
      products = reconciled.products_group.children.select do |reference|
        reference.path == 'ColumbaModelBApp.app'
      end
      assert_equal [model_b_targets.first.product_reference.uuid], products.map(&:uuid)
      refute reconciled.objects_by_uuid.key?(duplicate_id)
      refute reconciled.objects_by_uuid.key?(duplicate_product_id)
      assert_empty duplicate_graph_ids & reconciled.objects_by_uuid.keys,
                   'duplicate target left orphaned phase/build-file/configuration objects'
      attributes = reconciled.root_object.attributes.fetch('TargetAttributes', {})
      assert_empty attributes.keys - reconciled.targets.map(&:uuid)
      stale_proxy = reconciled.objects.any? do |object|
        object.is_a?(Xcodeproj::Project::Object::PBXContainerItemProxy) &&
          object.remote_global_id_string == duplicate_id
      end
      refute stale_proxy
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_shipping_cleanup_preserves_shared_extension_owned_graph
    Dir.mktmpdir('columba-shared-extension-product') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)

      fixture = Xcodeproj::Project.open(temporary_project)
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      protected_phase = fixture.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
      protected_phase.name = 'Embed App Extensions'
      protected_phase.symbol_dst_subfolder_spec = :plug_ins
      protected_file = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
      protected_file.file_ref = extension.product_reference
      protected_file.settings = { 'ATTRIBUTES' => ['ProtectedExtensionOwner'] }
      protected_phase.files << protected_file
      extension.build_phases << protected_phase
      shipping.build_phases << protected_phase
      fixture.save

      # Also share the extension-product build file with a non-embed shipping
      # phase. xcodeproj cannot serialize two PBXBuildFile parents, so inject the
      # second phase membership into the otherwise-valid fixture.
      pbxproj_path = File.join(temporary_project, 'project.pbxproj')
      pbxproj = File.read(pbxproj_path)
      shipping_phase_id = shipping.frameworks_build_phase.uuid
      phase_header = "\t\t#{shipping_phase_id} /* Frameworks */ = {"
      phase_start = pbxproj.index(phase_header) or raise 'missing shipping Frameworks phase'
      files_start = pbxproj.index("\t\t\tfiles = (\n", phase_start) or raise 'missing shipping Frameworks files'
      insertion_point = files_start + "\t\t\tfiles = (\n".length
      pbxproj.insert(insertion_point,
                     "\t\t\t\t#{protected_file.uuid} /* malformed shared extension product */,\n")
      File.write(pbxproj_path, pbxproj)

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_shipping = mutated.targets.find { |target| target.name == 'ColumbaApp' }
      mutated_extension = mutated.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      assert_includes mutated_shipping.build_phases.map(&:uuid), protected_phase.uuid
      assert mutated_shipping.frameworks_build_phase.files.any? { |file| file.uuid == protected_file.uuid }
      before = target_graph_signature(mutated_extension)

      run_reconciler(temporary_project, 'shared-extension-ownership')

      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
      reconciled_extension = reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      refute reconciled_shipping.dependencies.any? { |dependency| dependency.target == reconciled_extension }
      refute reconciled_shipping.build_phases.any? { |phase| extension_embed_phase?(phase) }
      refute(reconciled_shipping.build_phases.flat_map(&:files).any? do |file|
        file.file_ref == reconciled_extension.product_reference
      end)
      assert_equal before, target_graph_signature(reconciled_extension),
                   'shipping cleanup mutated the protected extension graph'

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
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_reconciler_authoritatively_repairs_model_b_onboarding_mapping
    Dir.mktmpdir('columba-modelb-onboarding') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      debug = model_b.build_configurations.find { |configuration| configuration.name == 'Debug' }
      debug_swift = model_b.build_configurations.find { |configuration| configuration.name == 'Debug-Swift' }
      debug.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
        (compilation_tokens(debug) + [ONBOARDING_FLAG, 'UNRELATED_MODEL_B_CONDITION']).uniq.join(' ')
      debug_swift.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
        (compilation_tokens(debug_swift) - [ONBOARDING_FLAG] + ['OTHER_MODEL_B_CONDITION']).uniq.join(' ')
      fixture.save

      run_reconciler(temporary_project, 'onboarding-mapping')
      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      reconciled_model_b.build_configurations.each do |configuration|
        tokens = compilation_tokens(configuration)
        if configuration.name.end_with?('-Swift')
          assert_includes tokens, ONBOARDING_FLAG, configuration.name
        else
          refute_includes tokens, ONBOARDING_FLAG, configuration.name
        end
      end
      assert_includes compilation_tokens(
        reconciled_model_b.build_configurations.find { |configuration| configuration.name == 'Debug' }
      ), 'UNRELATED_MODEL_B_CONDITION'
      assert_includes compilation_tokens(
        reconciled_model_b.build_configurations.find { |configuration| configuration.name == 'Debug-Swift' }
      ), 'OTHER_MODEL_B_CONDITION'
      assert_second_run_byte_idempotent(temporary_project)
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
      before = target_graph_signature(
        mutated.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      )

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
      assert_equal before, target_graph_signature(reconciled_extension),
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
