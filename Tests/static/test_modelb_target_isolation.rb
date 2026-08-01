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
MIGRATION_FLAG = 'COLUMBA_MIGRATION_ENABLED'
RNODE_FLAG = 'COLUMBA_RNODE_ENABLED'
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
  Sources/RNSBackendSwift/SwiftRNSBackend.swift
  Sources/Shared/NomadNetFetch.swift
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
PYTHON_ONLY_SOURCE_PATHS = %w[
  Sources/ColumbaApp/Python/Models/PyAnnounce.swift
  Sources/ColumbaApp/Python/Models/PyMessage.swift
  Sources/ColumbaApp/Python/Models/PyConversation.swift
  Sources/ColumbaApp/Python/Models/PyLocalIdentity.swift
  Sources/PythonBridge/PythonBridge.swift
  Sources/PythonBridge/PythonRuntime.swift
  Sources/RNSBackendPy/PythonRNSBackend.swift
  Sources/ColumbaApp/Services/PythonNetworkTransport.swift
  Sources/PythonBridge/PythonBLECallbackBridge.swift
  Sources/PythonBridge/PythonRNodeBLEBridge.swift
].freeze
PYTHON_FRAMEWORK_PATH = 'Frameworks/Python.xcframework'
PYTHON_RESOURCE_PATH = 'app'
PYTHON_BRIDGING_HEADER = 'Sources/PythonBridge/ColumbaPython-Bridging-Header.h'
PYTHON_NATIVE_EXPORTS_FILE = 'Sources/ColumbaApp/Resources/ColumbaApp.exports'
PYTHON_EMBED_PHASE_NAME = 'Embed Frameworks'
PYTHON_SHELL_PHASE_NAME = 'Install Python stdlib & process dylibs'
PYTHON_INSTALL_SCRIPT = <<~'SH'.freeze
  set -e

  # Copy platform-appropriate wheels into <app>/app_packages/ before
  # install_python processes the .so extensions inside them.
  case "$EFFECTIVE_PLATFORM_NAME" in
    -iphoneos)         WHEELS_SRC="$PROJECT_DIR/wheels-iphoneos" ;;
    -iphonesimulator)  WHEELS_SRC="$PROJECT_DIR/wheels-iphonesimulator" ;;
    *) echo "error: unsupported platform $EFFECTIVE_PLATFORM_NAME" >&2; exit 1 ;;
  esac
  [ -d "$WHEELS_SRC" ] || {
    echo "error: $WHEELS_SRC missing — run support/fetch-wheels.sh" >&2
    exit 1
  }
  [ -s "$WHEELS_SRC/ble_reticulum/BLEInterface.py" ] || {
    echo "error: ble_reticulum missing from $WHEELS_SRC — run support/fetch-wheels.sh" >&2
    exit 1
  }
  mkdir -p "$CODESIGNING_FOLDER_PATH/app_packages"
  rsync -au --delete "$WHEELS_SRC/" "$CODESIGNING_FOLDER_PATH/app_packages/"

  source "$PROJECT_DIR/Frameworks/Python.xcframework/build/utils.sh"
  install_python Frameworks/Python.xcframework app_packages
SH
MODEL_B_ONLY_TEST_SOURCE_PATHS = %w[
  Tests/ColumbaAppTests/BLESeamDriverTests.swift
  Tests/ColumbaAppTests/RNodeSeamTests.swift
].freeze
SHIPPING_TEST_SOURCE_PATHS = %w[
  Tests/ColumbaAppTests/MicronParserTests.swift
  Tests/ColumbaAppTests/AudioRingBufferTests.swift
  Tests/ColumbaAppTests/AudioManagerConfigChangeTests.swift
  Tests/ColumbaAppTests/CallManagerCallKitTests.swift
  Tests/ColumbaAppTests/MessageFormattedTimeTests.swift
  Tests/ColumbaAppTests/AnnounceClassificationTests.swift
  Tests/ColumbaAppTests/MigrationRoundTripTests.swift
  Tests/ColumbaAppTests/IncomingMessageSizeLimitTests.swift
  Tests/ColumbaAppTests/PythonConfigWriterTests.swift
  Tests/ColumbaAppTests/RuntimeFlavorTests.swift
].freeze
MODEL_B_DECLARATIONS_ABSENT_FROM_SHIPPING = %w[
  SwiftRNSBackend
  NomadNetFetch
  ModelBRNodeService
  BLESeamTransport
  BLEDriverSeamMessage
  AppGroupBLEDriver
  RNodeSeamWire
  RNodeSeamMessage
  AppGroupRNodeSeamTransport
  AppGroupRNodeSeamWire
  AppGroupRNodeServer
  RNodeSeamConfig
  RNodeLinkState
  PropagationSeamConfig
  PropagationSyncStateSnapshot
  ModelBInboundReplay
].freeze
SHIPPING_REQUIRED_SOURCE_PATHS = %w[
  Sources/ColumbaApp/Services/MessageRepository.swift
  Sources/Shared/SharedFrameQueue.swift
  Sources/Shared/ExtensionDiagLog.swift
].freeze

class ModelBTargetIsolationTests < Minitest::Test
  def setup
    @project = Xcodeproj::Project.open(PROJECT_PATH)
    @shipping = unique_target('ColumbaApp')
    @shipping_tests = unique_target('ColumbaAppTests')
    @model_b = unique_target('ColumbaModelBApp')
    @model_b_tests = unique_target('ColumbaModelBAppTests')
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

  def phase_file_paths(project, phase, root = REPOSITORY_ROOT)
    phase.files.each_with_object([]) do |build_file, paths|
      next unless build_file.file_ref

      paths << build_file.file_ref.real_path.relative_path_from(Pathname.new(root)).to_s
    end
  end

  def python_shell_metadata(phase)
    {
      name: phase.name,
      shell_path: phase.shell_path,
      shell_script: phase.shell_script,
      input_paths: phase.input_paths,
      output_paths: phase.output_paths,
      input_file_list_paths: phase.input_file_list_paths,
      output_file_list_paths: phase.output_file_list_paths,
      always_out_of_date: phase.always_out_of_date,
      show_env_vars_in_log: phase.show_env_vars_in_log,
      dependency_file: phase.dependency_file,
      build_action_mask: phase.build_action_mask,
      run_only_for_deployment_postprocessing: phase.run_only_for_deployment_postprocessing
    }
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

  def target_semantic_signature(project, target)
    {
      identity: [target.name, target.product_name, target.product_type],
      product: target.product_reference && [
        target.product_reference.path,
        target.product_reference.name,
        target.product_reference.explicit_file_type,
        target.product_reference.source_tree
      ],
      phases: target.build_phases.map do |phase|
        {
          isa: phase.isa,
          scalar_attributes: phase.class.simple_attributes.to_h do |attribute|
            [attribute.name, deep_copy(phase.public_send(attribute.name))]
          end,
          files: phase.files.map { |build_file| build_file_signature(build_file) }
        }
      end,
      package_products: target.package_product_dependencies.map do |dependency|
        package = dependency.package
        package_identity = if package.respond_to?(:repositoryURL)
                             package.repositoryURL
                           elsif package.respond_to?(:relative_path)
                             package.relative_path
                           end
        [dependency.product_name, package_identity]
      end,
      configurations: target.build_configurations.map do |configuration|
        base = configuration.base_configuration_reference
        [configuration.name, base&.display_name, deep_copy(configuration.build_settings)]
      end,
      configuration_list: [
        target.build_configuration_list.default_configuration_name,
        target.build_configuration_list.default_configuration_is_visible
      ],
      dependencies: target.dependencies.map { |dependency| dependency.target&.name },
      target_attributes: deep_copy(
        project.root_object.attributes.fetch('TargetAttributes', {}).fetch(target.uuid, nil)
      )
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
    assert_equal 24, MODEL_B_ONLY_SOURCE_PATHS.size
    assert_equal 10, PYTHON_ONLY_SOURCE_PATHS.size
    shipping_phases = @shipping.build_phases.reject { |phase| extension_embed_phase?(phase) }
    model_phases = @model_b.build_phases.reject { |phase| extension_embed_phase?(phase) }
    assert_equal [
      Xcodeproj::Project::Object::PBXSourcesBuildPhase,
      Xcodeproj::Project::Object::PBXFrameworksBuildPhase,
      Xcodeproj::Project::Object::PBXResourcesBuildPhase,
      Xcodeproj::Project::Object::PBXCopyFilesBuildPhase,
      Xcodeproj::Project::Object::PBXShellScriptBuildPhase
    ], shipping_phases.map(&:class)
    assert_equal shipping_phases.first(3).map { |phase| phase_signature(phase) },
                 model_phases.map { |phase| phase_signature(phase) }

    shipping_sources = source_paths(@shipping)
    model_b_sources = source_paths(@model_b)
    assert_empty MODEL_B_ONLY_SOURCE_PATHS & shipping_sources
    assert_empty MODEL_B_ONLY_SOURCE_PATHS - model_b_sources
    assert_empty SHIPPING_REQUIRED_SOURCE_PATHS - shipping_sources
    assert_empty SHIPPING_REQUIRED_SOURCE_PATHS - model_b_sources
    assert_empty PYTHON_ONLY_SOURCE_PATHS - shipping_sources
    assert_empty PYTHON_ONLY_SOURCE_PATHS & model_b_sources
    assert_equal (shipping_sources - PYTHON_ONLY_SOURCE_PATHS) + MODEL_B_ONLY_SOURCE_PATHS,
                 model_b_sources
    assert_equal MODEL_B_ONLY_SOURCE_METADATA, isolated_source_metadata(@model_b)

    shipping_framework_paths = phase_file_paths(@project, @shipping.frameworks_build_phase)
    model_framework_paths = phase_file_paths(@project, @model_b.frameworks_build_phase)
    assert_equal 1, shipping_framework_paths.count(PYTHON_FRAMEWORK_PATH)
    refute_includes model_framework_paths, PYTHON_FRAMEWORK_PATH
    assert_equal shipping_framework_paths - [PYTHON_FRAMEWORK_PATH], model_framework_paths

    shipping_resource_paths = phase_file_paths(@project, @shipping.resources_build_phase)
    model_resource_paths = phase_file_paths(@project, @model_b.resources_build_phase)
    assert_equal 1, shipping_resource_paths.count(PYTHON_RESOURCE_PATH)
    refute_includes model_resource_paths, PYTHON_RESOURCE_PATH
    assert_equal shipping_resource_paths - [PYTHON_RESOURCE_PATH], model_resource_paths

    embed_phases = @shipping.build_phases.select do |phase|
      phase.respond_to?(:name) && phase.name == PYTHON_EMBED_PHASE_NAME
    end
    assert_equal 1, embed_phases.size
    embed = embed_phases.first
    assert_equal [PYTHON_FRAMEWORK_PATH], phase_file_paths(@project, embed)
    assert_equal({ 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] }, embed.files.first.settings)
    assert_equal '', embed.dst_path
    assert_equal '10', embed.dst_subfolder_spec.to_s
    assert_equal '2147483647', embed.build_action_mask
    assert_equal '0', embed.run_only_for_deployment_postprocessing

    shell_phases = @shipping.build_phases.select do |phase|
      phase.respond_to?(:name) && phase.name == PYTHON_SHELL_PHASE_NAME
    end
    assert_equal 1, shell_phases.size
    assert_equal({
      name: PYTHON_SHELL_PHASE_NAME,
      shell_path: '/bin/sh',
      shell_script: PYTHON_INSTALL_SCRIPT,
      input_paths: ['$(PROJECT_DIR)/Frameworks/Python.xcframework/build/utils.sh'],
      output_paths: [],
      input_file_list_paths: [],
      output_file_list_paths: [],
      always_out_of_date: '1',
      show_env_vars_in_log: '0',
      dependency_file: nil,
      build_action_mask: '2147483647',
      run_only_for_deployment_postprocessing: '0'
    }, python_shell_metadata(shell_phases.first))
    refute_includes shell_phases.first.shell_script, 'COLUMBA_BACKEND_SWIFT'
    assert_equal [nil, nil, nil, PYTHON_EMBED_PHASE_NAME, PYTHON_SHELL_PHASE_NAME],
                 shipping_phases.map { |phase| phase.respond_to?(:name) ? phase.name : nil }
    model_b_python_phases = @model_b.build_phases.select do |phase|
      phase.respond_to?(:name) && [PYTHON_EMBED_PHASE_NAME, PYTHON_SHELL_PHASE_NAME].include?(phase.name)
    end
    assert_empty model_b_python_phases
    @shipping.build_configurations.each do |configuration|
      assert_equal PYTHON_BRIDGING_HEADER,
                   configuration.build_settings['SWIFT_OBJC_BRIDGING_HEADER']
      if configuration.name == 'Release'
        assert_equal PYTHON_NATIVE_EXPORTS_FILE,
                     configuration.build_settings['EXPORTED_SYMBOLS_FILE']
        assert_equal 'non-global', configuration.build_settings['STRIP_STYLE']
      else
        refute configuration.build_settings.key?('EXPORTED_SYMBOLS_FILE')
        refute configuration.build_settings.key?('STRIP_STYLE')
      end
    end
    @model_b.build_configurations.each do |configuration|
      refute configuration.build_settings.key?('SWIFT_OBJC_BRIDGING_HEADER')
      refute configuration.build_settings.key?('EXPORTED_SYMBOLS_FILE')
      refute configuration.build_settings.key?('STRIP_STYLE')
    end

    shipping_products = @shipping.package_product_dependencies.map(&:product_name)
    model_b_products = @model_b.package_product_dependencies.map(&:product_name)
    assert_equal 1, shipping_products.count('ReticulumSwift')
    assert_includes model_b_products, 'ReticulumSwift'
    assert_includes shipping_products, 'LXMFSwift'
    assert_equal shipping_products, model_b_products
    @shipping.package_product_dependencies.each do |left|
      right = @model_b.package_product_dependencies.find do |candidate|
        candidate.product_name == left.product_name
      end
      refute_nil right
      refute_same left, right
      assert_same left.package, right.package
    end
    [@shipping, @model_b].each do |target|
      dependency = target.package_product_dependencies.find do |candidate|
        candidate.product_name == 'ReticulumSwift'
      end
      files = target.frameworks_build_phase.files.select do |file|
        file.product_ref&.product_name == 'ReticulumSwift'
      end
      assert_equal 1, files.size
      assert_equal dependency.uuid, files.first.product_ref.uuid
    end
    shipping_reticulum = @shipping.package_product_dependencies.find do |dependency|
      dependency.product_name == 'ReticulumSwift'
    end
    model_b_reticulum = @model_b.package_product_dependencies.find do |dependency|
      dependency.product_name == 'ReticulumSwift'
    end
    refute_equal shipping_reticulum.uuid, model_b_reticulum.uuid
    assert_equal shipping_reticulum.package.uuid, model_b_reticulum.package.uuid
  end

  def test_reconciler_repairs_shipping_source_and_reticulum_mutations
    Dir.mktmpdir('columba-modelb-source-package-mutation') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }

      excluded_refs = model_b.source_build_phase.files.each_with_object({}) do |file, references|
        path = file.file_ref.real_path.relative_path_from(Pathname.new(directory)).to_s
        references[path] = file.file_ref if MODEL_B_ONLY_SOURCE_PATHS.include?(path)
      end
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

      shipping_reticulum = shipping.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      refute_nil shipping_reticulum
      shipping_reticulum_id = shipping_reticulum.uuid
      shipping.package_product_dependencies.delete_if do |dependency|
        dependency.uuid == shipping_reticulum.uuid
      end
      shipping.frameworks_build_phase.files.select do |file|
        file.product_ref&.uuid == shipping_reticulum.uuid
      end.each(&:remove_from_project)
      shipping_reticulum.remove_from_project if shipping_reticulum.referrers.empty?
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
      refute_includes mutated_shipping.package_product_dependencies.map(&:product_name), 'ReticulumSwift'
      refute(mutated_shipping.frameworks_build_phase.files.any? do |file|
        file.product_ref&.product_name == 'ReticulumSwift'
      end)
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
      assert_equal (reconciled_shipping_sources - PYTHON_ONLY_SOURCE_PATHS) + MODEL_B_ONLY_SOURCE_PATHS,
                   reconciled_model_b_sources
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
      assert_equal 1, reconciled_shipping.package_product_dependencies.count { |dependency|
        dependency.product_name == 'ReticulumSwift'
      }
      shipping_reticulum_file = reconciled_shipping.frameworks_build_phase.files.select do |file|
        file.product_ref&.product_name == 'ReticulumSwift'
      end
      assert_equal 1, shipping_reticulum_file.size
      reconciled_shipping_reticulum = reconciled_shipping.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      assert_equal reconciled_shipping_reticulum.uuid, shipping_reticulum_file.first.product_ref.uuid
      refute_equal shipping_reticulum_id, shipping_reticulum_file.first.product_ref.uuid,
                   'fixture did not force recreation of shipping ReticulumSwift linkage'
      assert_equal extension_before, target_graph_signature(reconciled_extension)
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_reconciler_repairs_complete_python_ownership_matrix_and_malformed_sharing
    Dir.mktmpdir('columba-python-ownership-mutation') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      canonical_shipping = target_semantic_signature(fixture, shipping)
      canonical_model_b = target_semantic_signature(fixture, model_b)

      references = fixture.files.to_h do |reference|
        absolute = Pathname.new(File.expand_path(reference.real_path.to_s, directory))
        [absolute.relative_path_from(Pathname.new(directory)).to_s, reference]
      end
      removed_shipping_ids = []
      PYTHON_ONLY_SOURCE_PATHS.each do |path|
        build_file = shipping.source_build_phase.files.find do |candidate|
          candidate.file_ref&.uuid == references.fetch(path).uuid
        end
        refute_nil build_file, "fixture lacks shipping Python source #{path}"
        removed_shipping_ids << build_file.uuid
        build_file.remove_from_project

        leaked = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
        leaked.file_ref = references.fetch(path)
        leaked.settings = { 'COMPILER_FLAGS' => '-DSTALE_PYTHON_IN_MODEL_B' }
        leaked.platform_filter = 'macos'
        leaked.platform_filters = %w[ios macos]
        model_b.source_build_phase.files << leaked
      end

      [
        [shipping.frameworks_build_phase, model_b.frameworks_build_phase, PYTHON_FRAMEWORK_PATH],
        [shipping.resources_build_phase, model_b.resources_build_phase, PYTHON_RESOURCE_PATH]
      ].each do |shipping_phase, model_phase, path|
        build_file = shipping_phase.files.find do |candidate|
          candidate.file_ref&.uuid == references.fetch(path).uuid
        end
        refute_nil build_file, "fixture lacks shipping Python membership #{path}"
        removed_shipping_ids << build_file.uuid
        build_file.remove_from_project

        leaked = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
        leaked.file_ref = references.fetch(path)
        leaked.settings = { 'ATTRIBUTES' => ['StaleModelBLeak'] }
        model_phase.files << leaked
      end

      shipping.build_configurations.each do |configuration|
        configuration.build_settings.delete('SWIFT_OBJC_BRIDGING_HEADER')
      end
      model_b.build_configurations.each do |configuration|
        configuration.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'Stale/Python.h'
      end

      embed = shipping.build_phases.find do |phase|
        phase.respond_to?(:name) && phase.name == PYTHON_EMBED_PHASE_NAME
      end
      shell = shipping.build_phases.find do |phase|
        phase.respond_to?(:name) && phase.name == PYTHON_SHELL_PHASE_NAME
      end
      refute_nil embed
      refute_nil shell
      embed.dst_path = 'stale/embed/path'
      embed.dst_subfolder_spec = '7'
      embed.build_action_mask = '1'
      embed.run_only_for_deployment_postprocessing = '1'
      embed.files.first.settings = { 'ATTRIBUTES' => ['StaleEmbedMetadata'] }
      shell.shell_path = '/bin/false'
      shell.shell_script = 'echo stale'
      shell.input_paths = ['stale-input']
      shell.output_paths = ['stale-output']
      shell.input_file_list_paths = ['stale-input-list']
      shell.output_file_list_paths = ['stale-output-list']
      shell.always_out_of_date = '0'
      shell.show_env_vars_in_log = '1'
      shell.dependency_file = 'stale-dependency'
      shell.build_action_mask = '1'
      shell.run_only_for_deployment_postprocessing = '1'

      # These malformed shared phases must be detached from both app targets,
      # not globally deleted or edited, because the protected extension owns them.
      extension.build_phases << embed
      extension.build_phases << shell
      model_b.build_phases << embed
      model_b.build_phases << shell

      protected_build_file = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
      protected_build_file.file_ref = references.fetch(PYTHON_ONLY_SOURCE_PATHS.first)
      protected_build_file.settings = { 'COMPILER_FLAGS' => '-DPROTECTED_EXTENSION_OWNER' }
      extension.source_build_phase.files << protected_build_file
      protected_ids = [embed.uuid, shell.uuid, embed.files.first.uuid, protected_build_file.uuid]
      fixture.save

      # xcodeproj cannot serialize a PBXBuildFile under multiple phases. Inject
      # the protected extension build file into both malformed app Sources phases.
      pbxproj_path = File.join(temporary_project, 'project.pbxproj')
      pbxproj = File.read(pbxproj_path)
      [shipping.source_build_phase.uuid, model_b.source_build_phase.uuid].each do |phase_id|
        phase_header = "\t\t#{phase_id} /* Sources */ = {"
        phase_start = pbxproj.index(phase_header) or raise "missing Sources phase #{phase_id}"
        files_start = pbxproj.index("\t\t\tfiles = (\n", phase_start) or raise 'missing Sources files'
        insertion_point = files_start + "\t\t\tfiles = (\n".length
        pbxproj.insert(
          insertion_point,
          "\t\t\t\t#{protected_build_file.uuid} /* malformed shared Python source */,\n"
        )
      end
      File.write(pbxproj_path, pbxproj)

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_shipping = mutated.targets.find { |target| target.name == 'ColumbaApp' }
      mutated_model_b = mutated.targets.find { |target| target.name == 'ColumbaModelBApp' }
      mutated_extension = mutated.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      assert_empty PYTHON_ONLY_SOURCE_PATHS - source_paths(mutated_model_b, directory)
      assert_equal 1, source_paths(mutated_shipping, directory).count(PYTHON_ONLY_SOURCE_PATHS.first)
      assert_empty removed_shipping_ids & mutated.objects_by_uuid.keys
      assert_empty protected_ids - mutated.objects_by_uuid.keys
      assert_equal 'Stale/Python.h',
                   mutated_model_b.build_configurations.first.build_settings['SWIFT_OBJC_BRIDGING_HEADER']
      extension_before = target_graph_signature(mutated_extension)
      tests_before = target_graph_signature(
        mutated.targets.find { |target| target.name == 'ColumbaAppTests' }
      )

      run_reconciler(temporary_project, 'complete-python-ownership')
      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
      reconciled_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      reconciled_extension = reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      reconciled_tests = reconciled.targets.find { |target| target.name == 'ColumbaAppTests' }

      assert_equal canonical_shipping, target_semantic_signature(reconciled, reconciled_shipping),
                   'shipping Python source/resource/framework/phase/config matrix was not restored exactly'
      assert_equal canonical_model_b, target_semantic_signature(reconciled, reconciled_model_b),
                   'Model B did not return to its exact Python-free graph'
      assert_equal extension_before, target_graph_signature(reconciled_extension),
                   'repair mutated the protected extension graph'
      assert_equal tests_before, target_graph_signature(reconciled_tests),
                   'repair mutated the Task 7 shipping-test graph'
      assert_empty removed_shipping_ids & reconciled.objects_by_uuid.keys,
                   'removed target-local Python build files became orphans'
      assert_empty protected_ids - reconciled.objects_by_uuid.keys,
                   'protected shared phase/build-file objects were globally deleted'
      assert_empty protected_ids & reconciled_shipping.build_phases.map(&:uuid)
      assert_empty protected_ids & reconciled_model_b.build_phases.map(&:uuid)
      refute_includes reconciled_shipping.source_build_phase.files.map(&:uuid), protected_build_file.uuid
      refute_includes reconciled_model_b.source_build_phase.files.map(&:uuid), protected_build_file.uuid

      phase_owners = Hash.new { |hash, key| hash[key] = [] }
      build_file_owners = Hash.new { |hash, key| hash[key] = [] }
      reconciled.targets.each do |target|
        target.build_phases.each { |phase| phase_owners[phase.uuid] << target.uuid }
      end
      reconciled.objects.each do |object|
        next unless object.respond_to?(:files)

        object.files.each { |build_file| build_file_owners[build_file.uuid] << object.uuid }
      end
      all_build_files = reconciled.objects.select do |object|
        object.is_a?(Xcodeproj::Project::Object::PBXBuildFile)
      end
      assert phase_owners.values.all?(&:one?), 'repair retained a multi-owner build phase'
      assert all_build_files.all? { |build_file| build_file_owners[build_file.uuid].one? },
             'repair retained an orphan or multi-owner PBXBuildFile'
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_reconciler_scopes_python_native_archive_settings_to_shipping
    Dir.mktmpdir('columba-python-native-settings') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }

      shipping.build_configurations.each do |configuration|
        configuration.build_settings.delete('EXPORTED_SYMBOLS_FILE')
        configuration.build_settings['STRIP_STYLE'] = 'all'
      end
      model_b.build_configurations.each do |configuration|
        configuration.build_settings['EXPORTED_SYMBOLS_FILE'] = 'Stale/Exports.list'
        configuration.build_settings['STRIP_STYLE'] = 'non-global'
      end
      fixture.save

      run_reconciler(temporary_project, 'python-native-settings')
      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
      reconciled_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }

      reconciled_shipping.build_configurations.each do |configuration|
        if configuration.name == 'Release'
          assert_equal PYTHON_NATIVE_EXPORTS_FILE,
                       configuration.build_settings['EXPORTED_SYMBOLS_FILE']
          assert_equal 'non-global', configuration.build_settings['STRIP_STYLE']
        else
          refute configuration.build_settings.key?('EXPORTED_SYMBOLS_FILE')
          refute configuration.build_settings.key?('STRIP_STYLE')
        end
      end
      reconciled_model_b.build_configurations.each do |configuration|
        refute configuration.build_settings.key?('EXPORTED_SYMBOLS_FILE')
        refute configuration.build_settings.key?('STRIP_STYLE')
      end
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_reconciler_localizes_each_shared_shipping_canonical_phase_before_python_repair
    cases = [
      [:sources, PYTHON_ONLY_SOURCE_PATHS.first],
      [:frameworks, PYTHON_FRAMEWORK_PATH],
      [:resources, PYTHON_RESOURCE_PATH]
    ]
    cases.each do |kind, missing_path|
      Dir.mktmpdir("columba-shared-shipping-#{kind}") do |directory|
        temporary_project = File.join(directory, 'Columba.xcodeproj')
        FileUtils.cp_r(PROJECT_PATH, temporary_project)
        fixture = Xcodeproj::Project.open(temporary_project)
        shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
        extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
        protected_extension_before = target_graph_signature(extension)
        phase = case kind
                when :sources then shipping.source_build_phase
                when :frameworks then shipping.frameworks_build_phase
                when :resources then shipping.resources_build_phase
                end
        phase_index = shipping.build_phases.index { |candidate| candidate.uuid == phase.uuid }
        canonical_signature = {
          isa: phase.isa,
          scalar_attributes: phase.class.simple_attributes.to_h do |attribute|
            [attribute.name, deep_copy(phase.public_send(attribute.name))]
          end,
          files: phase.files.map { |build_file| build_file_signature(build_file) }
        }
        missing_file = phase.files.find do |build_file|
          next false unless build_file.file_ref

          build_file.file_ref.real_path.relative_path_from(Pathname.new(directory)).to_s == missing_path
        end
        refute_nil missing_file, "fixture lacks #{missing_path} in shipping #{kind}"
        contaminated_file = case kind
                            when :sources
                              phase.files.find do |build_file|
                                next false unless build_file.file_ref

                                path = build_file.file_ref.real_path.relative_path_from(
                                  Pathname.new(directory)
                                ).to_s
                                PYTHON_ONLY_SOURCE_PATHS.include?(path) &&
                                  build_file.uuid != missing_file.uuid
                              end
                            when :frameworks
                              phase.files.find do |build_file|
                                build_file.product_ref&.product_name == 'ReticulumSwift'
                              end
                            when :resources
                              nil
                            end
        refute_nil contaminated_file, "fixture lacks contamination candidate for #{kind}" unless kind == :resources
        protected_local_phase = if kind == :frameworks
                                  extension.frameworks_build_phase
                                else
                                  extension.source_build_phase
                                end
        protected_local_phase_id = protected_local_phase.uuid
        contaminated_file_id = contaminated_file&.uuid
        missing_file.remove_from_project
        # Save the missing-member mutation first, then inject the canonical phase
        # UUID into the extension target. Xcodeproj normalizes a shared phase if
        # asked to serialize it through the object model, so the malformed
        # multi-owner relationship must be introduced in project.pbxproj.
        shared_phase_id = phase.uuid
        protected_phase_file_ids = phase.files.map(&:uuid)
        fixture.save
        pbxproj_path = File.join(temporary_project, 'project.pbxproj')
        pbxproj = File.read(pbxproj_path)
        target_header = "\t\t#{extension.uuid} /* ColumbaNetworkExtension */ = {"
        target_start = pbxproj.index(target_header) or raise 'missing extension target in fixture'
        phases_start = pbxproj.index("\t\t\tbuildPhases = (\n", target_start) or
          raise 'missing extension buildPhases in fixture'
        insertion_point = phases_start + "\t\t\tbuildPhases = (\n".length
        pbxproj.insert(
          insertion_point,
          "\t\t\t\t#{shared_phase_id} /* malformed shared shipping #{kind} phase */,\n"
        )
        if contaminated_file_id
          protected_header = "\t\t#{protected_local_phase_id} /* #{protected_local_phase.display_name} */ = {"
          protected_start = pbxproj.index(protected_header) or raise 'missing protected local phase in fixture'
          protected_files_start = pbxproj.index("\t\t\tfiles = (\n", protected_start) or
            raise 'missing protected local phase files in fixture'
          protected_insertion = protected_files_start + "\t\t\tfiles = (\n".length
          pbxproj.insert(
            protected_insertion,
            "\t\t\t\t#{contaminated_file_id} /* malformed independently shared build file */,\n"
          )
        end
        File.write(pbxproj_path, pbxproj)

        mutated = Xcodeproj::Project.open(temporary_project)
        mutated_shipping = mutated.targets.find { |target| target.name == 'ColumbaApp' }
        mutated_extension = mutated.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
        assert_includes mutated_shipping.build_phases.map(&:uuid), shared_phase_id,
                        "#{kind} shipping phase mutation did not survive serialization"
        assert_includes mutated_extension.build_phases.map(&:uuid), shared_phase_id,
                        "#{kind} shared-phase mutation did not survive serialization"
        if contaminated_file_id
          assert mutated_extension.build_phases.any? { |candidate|
            candidate.uuid == protected_local_phase_id &&
              candidate.files.any? { |build_file| build_file.uuid == contaminated_file_id }
          }, "#{kind} independently shared build-file mutation did not survive serialization"
        end
        run_reconciler(temporary_project, "shared-shipping-#{kind}")
        reconciled = Xcodeproj::Project.open(temporary_project)
        reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
        reconciled_extension = reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
        local_phase = reconciled_shipping.build_phases.fetch(phase_index)

        refute_equal shared_phase_id, local_phase.uuid,
                     "shipping retained protected shared #{kind} phase"
        assert_equal protected_extension_before, target_graph_signature(reconciled_extension),
                     "#{kind} localization mutated protected extension phase/build-file UUIDs or metadata"
        if contaminated_file_id
          refute_includes reconciled_extension.build_phases.flat_map(&:files).map(&:uuid),
                          contaminated_file_id,
                          "#{kind} repair retained an independently shared shipping PBXBuildFile"
        end
        assert_empty protected_phase_file_ids & local_phase.files.map(&:uuid),
                     "#{kind} localization reused protected PBXBuildFiles"
        assert_equal canonical_signature, {
          isa: local_phase.isa,
          scalar_attributes: local_phase.class.simple_attributes.to_h do |attribute|
            [attribute.name, deep_copy(local_phase.public_send(attribute.name))]
          end,
          files: local_phase.files.map { |build_file| build_file_signature(build_file) }
        }, "shipping #{kind} phase was not restored with canonical attributes, metadata, and order"
        assert_equal 1, phase_file_paths(reconciled, local_phase, directory).count(missing_path)

        phase_owners = Hash.new { |hash, key| hash[key] = [] }
        build_file_owners = Hash.new { |hash, key| hash[key] = [] }
        reconciled.targets.each do |target|
          target.build_phases.each { |candidate| phase_owners[candidate.uuid] << target.uuid }
        end
        reconciled.objects.each do |object|
          next unless object.respond_to?(:files)

          object.files.each { |build_file| build_file_owners[build_file.uuid] << object.uuid }
        end
        all_build_files = reconciled.objects.select do |object|
          object.is_a?(Xcodeproj::Project::Object::PBXBuildFile)
        end
        assert phase_owners.values.all?(&:one?), "#{kind} repair retained a shared phase"
        assert all_build_files.all? { |build_file| build_file_owners[build_file.uuid].one? },
               "#{kind} repair retained an orphan/shared PBXBuildFile"
        assert_second_run_byte_idempotent(temporary_project)
      end
    end
  end

  def test_reconciler_removes_build_file_only_contamination_from_protected_phases
    cases = %i[source framework resource package]
    cases.each do |kind|
      Dir.mktmpdir("columba-shared-shipping-build-file-#{kind}") do |directory|
        temporary_project = File.join(directory, 'Columba.xcodeproj')
        FileUtils.cp_r(PROJECT_PATH, temporary_project)
        fixture = Xcodeproj::Project.open(temporary_project)
        shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
        extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
        shipping_phase, protected_phase, build_file = case kind
                                                      when :source
                                                        phase = shipping.source_build_phase
                                                        file = phase.files.find do |candidate|
                                                          phase_file_paths(fixture, phase, directory)
                                                            .include?(PYTHON_ONLY_SOURCE_PATHS.first) &&
                                                            candidate.file_ref&.real_path&.relative_path_from(
                                                              Pathname.new(directory)
                                                            )&.to_s == PYTHON_ONLY_SOURCE_PATHS.first
                                                        end
                                                        [phase, extension.source_build_phase, file]
                                                      when :framework
                                                        phase = shipping.frameworks_build_phase
                                                        file = phase.files.find do |candidate|
                                                          candidate.file_ref&.real_path&.relative_path_from(
                                                            Pathname.new(directory)
                                                          )&.to_s == PYTHON_FRAMEWORK_PATH
                                                        end
                                                        [phase, extension.frameworks_build_phase, file]
                                                      when :resource
                                                        phase = shipping.resources_build_phase
                                                        file = phase.files.find do |candidate|
                                                          candidate.file_ref&.real_path&.relative_path_from(
                                                            Pathname.new(directory)
                                                          )&.to_s == PYTHON_RESOURCE_PATH
                                                        end
                                                        [phase, extension.source_build_phase, file]
                                                      when :package
                                                        phase = shipping.frameworks_build_phase
                                                        file = phase.files.find do |candidate|
                                                          candidate.product_ref&.product_name == 'ReticulumSwift'
                                                        end
                                                        [phase, extension.frameworks_build_phase, file]
                                                      end
        refute_nil build_file, "fixture lacks shipping #{kind} build file"
        stale_duplicate_id = nil
        if %i[source package].include?(kind)
          stale_duplicate = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
          if build_file.product_ref
            stale_duplicate.product_ref = build_file.product_ref
          else
            stale_duplicate.file_ref = build_file.file_ref
          end
          stale_duplicate.settings = { 'COMPILER_FLAGS' => '-DSTALE_SHIPPING_DUPLICATE' }
          shipping_phase.files << stale_duplicate
          stale_duplicate_id = stale_duplicate.uuid
        end
        shipping_phase_id = shipping_phase.uuid
        build_file_id = build_file.uuid
        shipping_phase_before = phase_signature(shipping_phase)
        extension_before = target_graph_signature(extension)
        protected_phase_id = protected_phase.uuid
        protected_phase_name = protected_phase.display_name
        fixture.save

        pbxproj_path = File.join(temporary_project, 'project.pbxproj')
        pbxproj = File.read(pbxproj_path)
        phase_header = "\t\t#{protected_phase_id} /* #{protected_phase_name} */ = {"
        phase_start = pbxproj.index(phase_header) or raise 'missing protected phase in fixture'
        files_start = pbxproj.index("\t\t\tfiles = (\n", phase_start) or
          raise 'missing protected phase files in fixture'
        insertion = files_start + "\t\t\tfiles = (\n".length
        pbxproj.insert(
          insertion,
          "\t\t\t\t#{build_file_id} /* malformed build-file-only contamination */,\n"
        )
        File.write(pbxproj_path, pbxproj)

        mutated = Xcodeproj::Project.open(temporary_project)
        mutated_extension = mutated.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
        assert_includes mutated_extension.build_phases.flat_map(&:files).map(&:uuid), build_file_id

        run_reconciler(temporary_project, "build-file-only-#{kind}")
        reconciled = Xcodeproj::Project.open(temporary_project)
        reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
        reconciled_extension = reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
        local_shipping_phase = reconciled_shipping.build_phases.find do |phase|
          phase.uuid == shipping_phase_id
        end
        refute_nil local_shipping_phase
        assert_equal shipping_phase_before, phase_signature(local_shipping_phase),
                     "#{kind} cleanup changed the canonical shipping phase"
        assert_equal extension_before, target_graph_signature(reconciled_extension),
                     "#{kind} cleanup did not restore the protected extension graph"
        refute_includes reconciled_extension.build_phases.flat_map(&:files).map(&:uuid), build_file_id
        assert_includes local_shipping_phase.files.map(&:uuid), build_file_id
        if stale_duplicate_id
          refute_includes local_shipping_phase.files.map(&:uuid), stale_duplicate_id
          refute_includes reconciled.objects_by_uuid.keys, stale_duplicate_id
        end
        owners = reconciled.objects.select do |object|
          object.respond_to?(:files) && object.files.any? { |candidate| candidate.uuid == build_file_id }
        end
        assert_equal [shipping_phase_id], owners.map(&:uuid)
        assert_second_run_byte_idempotent(temporary_project)
      end
    end
  end

  def test_reconciler_preserves_inverse_protected_build_file_contamination
    %i[source framework resource].each do |kind|
      Dir.mktmpdir("columba-inverse-build-file-#{kind}") do |directory|
        temporary_project = File.join(directory, 'Columba.xcodeproj')
        FileUtils.cp_r(PROJECT_PATH, temporary_project)
        fixture = Xcodeproj::Project.open(temporary_project)
        shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
        extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
        shipping_phase, protected_phase, canonical = case kind
                                                     when :source
                                                       phase = shipping.source_build_phase
                                                       file = phase.files.find do |candidate|
                                                         candidate.file_ref&.real_path&.relative_path_from(
                                                           Pathname.new(directory)
                                                         )&.to_s == PYTHON_ONLY_SOURCE_PATHS.first
                                                       end
                                                       [phase, extension.source_build_phase, file]
                                                     when :framework
                                                       phase = shipping.frameworks_build_phase
                                                       file = phase.files.find do |candidate|
                                                         candidate.file_ref&.display_name == File.basename(PYTHON_FRAMEWORK_PATH)
                                                       end
                                                       [phase, extension.frameworks_build_phase, file]
                                                     when :resource
                                                       phase = shipping.resources_build_phase
                                                       file = phase.files.find do |candidate|
                                                         candidate.file_ref&.display_name == File.basename(PYTHON_RESOURCE_PATH)
                                                       end
                                                       [phase, extension.source_build_phase, file]
                                                     end
        refute_nil canonical, "fixture lacks canonical shipping #{kind} build file"
        protected = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
        protected.file_ref = canonical.file_ref
        protected.settings = deep_copy(canonical.settings)
        protected.platform_filter = canonical.platform_filter
        protected.platform_filters = deep_copy(canonical.platform_filters)
        protected_phase.files << protected
        protected_id = protected.uuid
        shipping_phase_id = shipping_phase.uuid
        original_shipping_id = canonical.uuid
        fixture.save

        normalized = Xcodeproj::Project.open(temporary_project)
        shipping_before = target_graph_signature(
          normalized.targets.find { |target| target.name == 'ColumbaApp' }
        )
        extension_before = target_graph_signature(
          normalized.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
        )
        pbxproj_path = File.join(temporary_project, 'project.pbxproj')
        pbxproj = File.read(pbxproj_path)
        phase_header = "\t\t#{shipping_phase_id} /* #{shipping_phase.display_name} */ = {"
        phase_start = pbxproj.index(phase_header) or raise 'missing shipping phase in fixture'
        files_start = pbxproj.index("\t\t\tfiles = (\n", phase_start) or
          raise 'missing shipping phase files in fixture'
        insertion = files_start + "\t\t\tfiles = (\n".length
        pbxproj.insert(
          insertion,
          "\t\t\t\t#{protected_id} /* protected-owned inverse contamination */,\n"
        )
        File.write(pbxproj_path, pbxproj)

        run_reconciler(temporary_project, "inverse-build-file-#{kind}")
        reconciled = Xcodeproj::Project.open(temporary_project)
        reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
        reconciled_extension = reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
        assert_equal shipping_before, target_graph_signature(reconciled_shipping),
                     "#{kind} inverse cleanup changed shipping's canonical graph"
        assert_equal extension_before, target_graph_signature(reconciled_extension),
                     "#{kind} inverse cleanup deleted protected ownership"
        assert_includes reconciled_shipping.build_phases.flat_map(&:files).map(&:uuid), original_shipping_id
        refute_includes reconciled_shipping.build_phases.flat_map(&:files).map(&:uuid), protected_id
        assert_includes reconciled_extension.build_phases.flat_map(&:files).map(&:uuid), protected_id
        assert_second_run_byte_idempotent(temporary_project)
      end
    end
  end

  def test_reconciler_preserves_inverse_protected_package_build_file
    Dir.mktmpdir('columba-inverse-package-build-file') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      shipping_phase = shipping.frameworks_build_phase
      protected = extension.frameworks_build_phase.files.find do |build_file|
        build_file.product_ref&.product_name == 'ReticulumSwift'
      end
      shipping_reticulum = shipping_phase.files.find do |build_file|
        build_file.product_ref&.product_name == 'ReticulumSwift'
      end
      refute_nil protected
      refute_nil shipping_reticulum
      protected_id = protected.uuid
      shipping_id = shipping_reticulum.uuid
      shipping_before = target_graph_signature(shipping)
      extension_before = target_graph_signature(extension)
      fixture.save

      pbxproj_path = File.join(temporary_project, 'project.pbxproj')
      pbxproj = File.read(pbxproj_path)
      phase_header = "\t\t#{shipping_phase.uuid} /* Frameworks */ = {"
      phase_start = pbxproj.index(phase_header) or raise 'missing shipping Frameworks phase'
      files_start = pbxproj.index("\t\t\tfiles = (\n", phase_start) or
        raise 'missing shipping Frameworks files'
      insertion = files_start + "\t\t\tfiles = (\n".length
      pbxproj.insert(insertion, "\t\t\t\t#{protected_id} /* protected package contamination */,\n")
      File.write(pbxproj_path, pbxproj)

      run_reconciler(temporary_project, 'inverse-package-build-file')
      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
      reconciled_extension = reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      assert_equal shipping_before, target_graph_signature(reconciled_shipping)
      assert_equal extension_before, target_graph_signature(reconciled_extension)
      assert_includes reconciled_shipping.frameworks_build_phase.files.map(&:uuid), shipping_id
      refute_includes reconciled_shipping.frameworks_build_phase.files.map(&:uuid), protected_id
      assert_includes reconciled_extension.frameworks_build_phase.files.map(&:uuid), protected_id
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_reconciler_recreates_completely_missing_model_b_target_from_root_package_reference
    Dir.mktmpdir('columba-modelb-missing-target') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      expected_signature = target_semantic_signature(fixture, model_b)
      extension_before = target_graph_signature(extension)
      reticulum_dependency = model_b.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      root_package = reticulum_dependency.package
      root_package_id = root_package.uuid
      removed_ids = [model_b.uuid, model_b.product_reference.uuid,
                     model_b.build_configuration_list.uuid]
      removed_ids.concat(model_b.build_phases.flat_map do |phase|
        [phase.uuid] + phase.files.map(&:uuid)
      end)
      removed_ids.concat(model_b.build_configurations.map(&:uuid))
      removed_ids.concat(model_b.package_product_dependencies.map(&:uuid))
      removed_ids.concat(model_b.dependencies.flat_map do |dependency|
        [dependency.uuid, dependency.target_proxy&.uuid].compact
      end)
      refute_includes removed_ids, root_package_id

      fixture.targets.each do |target|
        target.dependencies.dup.each do |dependency|
          next unless dependency.target&.uuid == model_b.uuid

          proxy = dependency.target_proxy
          dependency.remove_from_project
          proxy.remove_from_project if proxy && proxy.referrers.empty?
        end
      end
      model_b.dependencies.dup.each do |dependency|
        proxy = dependency.target_proxy
        dependency.remove_from_project
        proxy.remove_from_project if proxy && proxy.referrers.empty?
      end
      model_b.build_phases.dup.each do |phase|
        phase.files.dup.each(&:remove_from_project)
        phase.remove_from_project
      end
      model_b.build_configurations.dup.each(&:remove_from_project)
      model_b.build_configuration_list.remove_from_project
      model_b.package_product_dependencies.dup.each do |dependency|
        model_b.package_product_dependencies.delete_if do |candidate|
          candidate.uuid == dependency.uuid
        end
        dependency.remove_from_project if dependency.referrers.empty?
      end
      product = model_b.product_reference
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      shipping_reticulum = shipping.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      shipping.package_product_dependencies.delete_if do |dependency|
        dependency.uuid == shipping_reticulum.uuid
      end
      shipping.frameworks_build_phase.files.select do |file|
        file.product_ref&.uuid == shipping_reticulum.uuid
      end.each(&:remove_from_project)
      shipping_reticulum.remove_from_project if shipping_reticulum.referrers.empty?
      fixture.root_object.attributes.fetch('TargetAttributes', {}).delete(model_b.uuid)
      model_b.remove_from_project
      product.remove_from_project if fixture.objects_by_uuid.key?(product.uuid)
      fixture.save

      mutated = Xcodeproj::Project.open(temporary_project)
      assert_nil mutated.targets.find { |target| target.name == 'ColumbaModelBApp' }
      refute_includes mutated.targets.find { |target| target.name == 'ColumbaApp' }
                              .package_product_dependencies.map(&:product_name), 'ReticulumSwift'
      assert mutated.objects_by_uuid.key?(root_package_id),
             'fixture removed the authoritative root Reticulum package reference'
      assert_empty removed_ids & mutated.objects_by_uuid.keys,
                   'fixture did not cleanly remove the old Model B target graph'

      run_reconciler(temporary_project, 'missing-target')
      reconciled = Xcodeproj::Project.open(temporary_project)
      recreated = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      refute_nil recreated
      assert_equal expected_signature, target_semantic_signature(reconciled, recreated),
                   'recreated Model B target differs from the authoritative target graph'
      assert_equal extension_before, target_graph_signature(
        reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      ), 'target recreation mutated the protected extension graph'
      assert reconciled.objects_by_uuid.key?(root_package_id)
      assert_includes reconciled.targets.find { |target| target.name == 'ColumbaApp' }
                               .package_product_dependencies.map(&:product_name), 'ReticulumSwift'
      assert_empty removed_ids & reconciled.objects_by_uuid.keys,
                   'recreation retained orphan nodes from the removed target graph'

      phase_owners = Hash.new { |hash, key| hash[key] = [] }
      build_file_owners = Hash.new { |hash, key| hash[key] = [] }
      reconciled.targets.each do |target|
        target.build_phases.each { |phase| phase_owners[phase.uuid] << target.uuid }
      end
      reconciled.objects.each do |object|
        next unless object.respond_to?(:files)

        object.files.each { |build_file| build_file_owners[build_file.uuid] << object.uuid }
      end
      assert phase_owners.values.all?(&:one?), 'recreated graph has a multi-owner phase'
      assert build_file_owners.values.all?(&:one?), 'recreated graph has a multi-owner build file'
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_configuration_flags_entitlements_and_identity_are_isolated
    assert_equal %w[Debug Release], @shipping.build_configurations.map(&:name)
    assert_equal @shipping.build_configurations.map(&:name), @model_b.build_configurations.map(&:name)
    identity_keys = %w[
      PRODUCT_BUNDLE_IDENTIFIER DEVELOPMENT_TEAM CODE_SIGN_IDENTITY
      CODE_SIGN_STYLE PROVISIONING_PROFILE PROVISIONING_PROFILE_SPECIFIER
      INFOPLIST_FILE PRODUCT_MODULE_NAME
    ]

    @shipping.build_configurations.zip(@model_b.build_configurations).each do |shipping, model_b|
      assert_equal ['COLUMBA_RUNTIME_PYTHON'], canonical_tokens(shipping), shipping.name
      assert_includes compilation_tokens(shipping), ONBOARDING_FLAG,
                      "shipping app lost shared onboarding in #{shipping.name}"
      assert_includes compilation_tokens(shipping), MIGRATION_FLAG,
                      "shipping app lost data migration in #{shipping.name}"
      assert_includes compilation_tokens(shipping), RNODE_FLAG,
                      "shipping app lost RNode setup in #{shipping.name}"
      assert_equal %w[COLUMBA_RUNTIME_MODEL_B ENABLE_NETWORK_EXTENSION COLUMBA_BACKEND_SWIFT],
                   canonical_tokens(model_b), model_b.name
      assert_includes compilation_tokens(model_b), ONBOARDING_FLAG,
                      "explicit Model B target lost onboarding in #{model_b.name}"
      assert_includes compilation_tokens(model_b), MIGRATION_FLAG,
                      "explicit Model B target lost data migration in #{model_b.name}"
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
      assert_includes compilation_tokens(test_configuration), ONBOARDING_FLAG,
                      "shipping tests lost shared onboarding in #{test_configuration.name}"
      assert_includes compilation_tokens(test_configuration), MIGRATION_FLAG,
                      "shipping tests lost data migration in #{test_configuration.name}"
      assert_includes compilation_tokens(test_configuration), RNODE_FLAG,
                      "shipping tests lost RNode setup in #{test_configuration.name}"
      assert_match(/ColumbaApp\.app/, test_configuration.build_settings.fetch('TEST_HOST'),
                   "TEST_HOST changed in #{test_configuration.name}")
      assert_equal '$(TEST_HOST)', test_configuration.build_settings.fetch('BUNDLE_LOADER'),
                   "BUNDLE_LOADER changed in #{test_configuration.name}"
    end
  end

  def test_model_b_seam_tests_have_only_the_model_b_test_host
    assert_equal 2, MODEL_B_ONLY_TEST_SOURCE_PATHS.size
    assert_empty MODEL_B_ONLY_TEST_SOURCE_PATHS & source_paths(@shipping_tests)
    assert_equal SHIPPING_TEST_SOURCE_PATHS, source_paths(@shipping_tests)
    assert_equal MODEL_B_ONLY_TEST_SOURCE_PATHS, source_paths(@model_b_tests)
    assert_equal [@model_b.uuid], @model_b_tests.dependencies.map { |dependency| dependency.target.uuid }
    attributes = @project.root_object.attributes.fetch('TargetAttributes')
    assert_equal @model_b.uuid, attributes.fetch(@model_b_tests.uuid).fetch('TestTargetID')

    products = @model_b_tests.package_product_dependencies
    assert_equal ['ReticulumSwift'], products.map(&:product_name)
    dependency = products.first
    host_dependency = @model_b.package_product_dependencies.find do |candidate|
      candidate.product_name == 'ReticulumSwift'
    end
    refute_equal host_dependency.uuid, dependency.uuid
    assert_equal host_dependency.package.uuid, dependency.package.uuid
    files = @model_b_tests.frameworks_build_phase.files.select do |file|
      file.product_ref&.product_name == 'ReticulumSwift'
    end
    assert_equal 1, files.size
    assert_equal dependency.uuid, files.first.product_ref.uuid
  end

  def test_reconciler_repairs_model_b_test_host_metadata_and_package_ownership
    Dir.mktmpdir('columba-modelb-test-host-package') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      shipping_tests = fixture.targets.find { |target| target.name == 'ColumbaAppTests' }
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      model_b_tests = fixture.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      fixture.root_object.attributes.fetch('TargetAttributes')
             .fetch(model_b_tests.uuid)['TestTargetID'] = shipping.uuid

      local_dependency = model_b_tests.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      local_build_file = model_b_tests.frameworks_build_phase.files.find do |build_file|
        build_file.product_ref&.uuid == local_dependency&.uuid
      end
      shared_dependencies = %w[ReticulumSwift LXMFSwift].map do |name|
        shipping_tests.package_product_dependencies.find { |dependency| dependency.product_name == name } or
          raise "shipping tests lack #{name} fixture dependency"
      end
      shared_build_files = shared_dependencies.map do |dependency|
        shipping_tests.frameworks_build_phase.files.find do |build_file|
          build_file.product_ref&.uuid == dependency.uuid
        end or raise "shipping tests lack #{dependency.product_name} fixture build file"
      end
      refute_nil local_build_file
      model_b_tests.package_product_dependencies.clear
      shared_dependencies.each do |dependency|
        model_b_tests.package_product_dependencies << dependency
      end
      fixture.save

      # Xcodeproj cannot serialize a shared PBXBuildFile, and can suppress a
      # malformed same-product productRef assignment. Inject both after saving.
      pbxproj_path = File.join(temporary_project, 'project.pbxproj')
      pbxproj = File.read(pbxproj_path)
      product_ref = /^(\s*#{local_build_file.uuid}\b.*\bproductRef = )#{local_dependency.uuid}(\b.*)$/
      raise 'missing Model B test ReticulumSwift productRef' unless pbxproj.sub!(
        product_ref, "\\1#{shared_dependencies.first.uuid}\\2"
      )
      phase_header = "\t\t#{model_b_tests.frameworks_build_phase.uuid} /* Frameworks */ = {"
      phase_start = pbxproj.index(phase_header) or raise 'missing Model B test Frameworks phase'
      files_start = pbxproj.index("\t\t\tfiles = (\n", phase_start) or raise 'missing Frameworks files'
      insertion_point = files_start + "\t\t\tfiles = (\n".length
      shared_entries = shared_build_files.map do |build_file|
        "\t\t\t\t#{build_file.uuid} /* malformed shared test package build file */,\n"
      end.join
      pbxproj.insert(insertion_point, shared_entries)
      File.write(pbxproj_path, pbxproj)

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_tests = mutated.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      assert_equal shipping.uuid,
                   mutated.root_object.attributes.fetch('TargetAttributes')
                          .fetch(mutated_tests.uuid).fetch('TestTargetID')
      assert_equal shared_dependencies.map(&:uuid),
                   mutated_tests.package_product_dependencies.map(&:uuid)
      assert_empty shared_build_files.map(&:uuid) -
                   mutated_tests.frameworks_build_phase.files.map(&:uuid)
      protected = [shipping, shipping_tests, model_b, extension].each_with_object({}) do |target, result|
        live = mutated.targets.find { |candidate| candidate.uuid == target.uuid }
        result[target.uuid] = target_graph_signature(live)
      end

      run_reconciler(temporary_project, 'Model B test host/package ownership')
      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_tests = reconciled.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      reconciled_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      assert_equal reconciled_model_b.uuid,
                   reconciled.root_object.attributes.fetch('TargetAttributes')
                             .fetch(reconciled_tests.uuid).fetch('TestTargetID')
      assert_equal ['ReticulumSwift'],
                   reconciled_tests.package_product_dependencies.map(&:product_name)
      repaired_dependency = reconciled_tests.package_product_dependencies.first
      refute_includes shared_dependencies.map(&:uuid), repaired_dependency.uuid
      host_dependency = reconciled_model_b.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      assert_equal host_dependency.package.uuid, repaired_dependency.package.uuid
      repaired_files = reconciled_tests.frameworks_build_phase.files.select do |build_file|
        build_file.product_ref&.product_name == 'ReticulumSwift'
      end
      assert_equal 1, repaired_files.size
      assert_equal repaired_dependency.uuid, repaired_files.first.product_ref.uuid
      assert_empty shared_build_files.map(&:uuid) &
                   reconciled_tests.frameworks_build_phase.files.map(&:uuid)
      protected.each do |uuid, signature|
        assert_equal signature, target_graph_signature(reconciled.objects_by_uuid.fetch(uuid)),
                     "Model B XCTest repair mutated protected target #{uuid}"
      end
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_reconciler_localizes_a_shipping_product_malformed_as_model_b_test_product
    Dir.mktmpdir('columba-modelb-test-shared-product') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      shipping_tests = fixture.targets.find { |target| target.name == 'ColumbaAppTests' }
      model_b_tests = fixture.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      shipping_product_id = shipping_tests.product_reference.uuid
      stale_product_id = model_b_tests.product_reference.uuid
      shipping_before = target_graph_signature(shipping_tests)
      fixture.save

      pbxproj_path = File.join(temporary_project, 'project.pbxproj')
      pbxproj = File.read(pbxproj_path)
      target_header = "\t\t#{model_b_tests.uuid} /* ColumbaModelBAppTests */ = {"
      target_start = pbxproj.index(target_header) or raise 'missing Model B XCTest target'
      target_end = pbxproj.index("\t\t};", target_start) or raise 'unterminated Model B XCTest target'
      target_text = pbxproj[target_start..target_end]
      raise 'missing Model B XCTest productReference' unless target_text.sub!(
        /productReference = #{stale_product_id}\b/, "productReference = #{shipping_product_id}"
      )
      pbxproj[target_start..target_end] = target_text
      File.write(pbxproj_path, pbxproj)

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_tests = mutated.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      assert_equal shipping_product_id, mutated_tests.product_reference.uuid
      run_reconciler(temporary_project, 'shared XCTest product')

      reconciled = Xcodeproj::Project.open(temporary_project)
      repaired_tests = reconciled.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      repaired_shipping = reconciled.targets.find { |target| target.name == 'ColumbaAppTests' }
      assert_equal shipping_before, target_graph_signature(repaired_shipping)
      assert_equal 'ColumbaAppTests.xctest', repaired_shipping.product_reference.path
      assert_equal 'ColumbaModelBAppTests.xctest', repaired_tests.product_reference.path
      refute_equal shipping_product_id, repaired_tests.product_reference.uuid
      refute reconciled.objects_by_uuid.key?(stale_product_id), 'stale Model B XCTest product survived'
      assert_equal [repaired_tests.product_reference.uuid], reconciled.products_group.children.select { |product|
        product.path == 'ColumbaModelBAppTests.xctest'
      }.map(&:uuid)
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_reconciler_recreates_missing_model_b_test_target_with_leftover_product
    Dir.mktmpdir('columba-modelb-test-missing-target') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      tests = fixture.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      old_target_id = tests.uuid
      old_product = tests.product_reference
      old_product_id = old_product.uuid
      removed_ids = tests.build_phases.flat_map { |phase| [phase.uuid] + phase.files.map(&:uuid) }
      removed_ids.concat(tests.build_configurations.map(&:uuid))
      removed_ids << tests.build_configuration_list.uuid
      removed_ids.concat(tests.dependencies.flat_map { |dependency| [dependency.uuid, dependency.target_proxy&.uuid].compact })
      removed_ids.concat(tests.package_product_dependencies.map(&:uuid))

      tests.dependencies.to_a.each do |dependency|
        proxy = dependency.target_proxy
        dependency.remove_from_project
        proxy.remove_from_project if proxy && proxy.referrers.empty?
      end
      tests.build_phases.to_a.each do |phase|
        phase.files.to_a.each(&:remove_from_project)
        phase.remove_from_project
      end
      tests.build_configurations.to_a.each(&:remove_from_project)
      tests.build_configuration_list.remove_from_project
      tests.package_product_dependencies.to_a.each do |dependency|
        tests.package_product_dependencies.delete_if { |candidate| candidate.uuid == dependency.uuid }
        dependency.remove_from_project if dependency.referrers.empty?
      end
      fixture.root_object.attributes.fetch('TargetAttributes', {}).delete(old_target_id)
      tests.remove_from_project
      fixture.products_group.children << old_product unless fixture.products_group.children.any? do |product|
        product.uuid == old_product_id
      end
      old_product.path = 'ColumbaModelBAppTests.xctest'
      fixture.save

      mutated = Xcodeproj::Project.open(temporary_project)
      assert_nil mutated.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      assert mutated.objects_by_uuid.key?(old_product_id), 'leftover product did not survive fixture setup'
      run_reconciler(temporary_project, 'missing XCTest target with leftover product')

      reconciled = Xcodeproj::Project.open(temporary_project)
      recreated = reconciled.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      refute_nil recreated
      refute_equal old_target_id, recreated.uuid
      refute_equal old_product_id, recreated.product_reference.uuid
      refute reconciled.objects_by_uuid.key?(old_product_id), 'leftover XCTest product became an orphan'
      assert_empty removed_ids & reconciled.objects_by_uuid.keys
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_reconciler_localizes_shared_test_phases_configurations_and_dependency_proxy
    Dir.mktmpdir('columba-modelb-test-shared-graph') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      shipping_app = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      shipping_tests = fixture.targets.find { |target| target.name == 'ColumbaAppTests' }
      model_b_tests = fixture.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      shared_phases = [shipping_tests.source_build_phase, shipping_tests.frameworks_build_phase,
                       shipping_app.resources_build_phase]
      shared_list = shipping_tests.build_configuration_list
      shared_dependency = shipping_tests.dependencies.first
      stale_list_id = model_b_tests.build_configuration_list.uuid
      stale_dependency = model_b_tests.dependencies.first
      stale_dependency_ids = [stale_dependency.uuid, stale_dependency.target_proxy.uuid]
      shipping_before = target_graph_signature(shipping_tests)
      shipping_app_before = target_graph_signature(shipping_app)
      fixture.save

      pbxproj_path = File.join(temporary_project, 'project.pbxproj')
      pbxproj = File.read(pbxproj_path)
      target_header = "\t\t#{model_b_tests.uuid} /* ColumbaModelBAppTests */ = {"
      target_start = pbxproj.index(target_header) or raise 'missing Model B XCTest target'
      target_end = pbxproj.index("\t\t};", target_start) or raise 'unterminated Model B XCTest target'
      target_text = pbxproj[target_start..target_end]
      shared_phase_entries = shared_phases.map do |phase|
        "\t\t\t\t#{phase.uuid} /* shared protected #{phase.isa} */,\n"
      end.join
      raise 'missing build phase list' unless target_text.sub!(
        /buildPhases = \(\n/, "buildPhases = (\n#{shared_phase_entries}"
      )
      raise 'missing configuration list' unless target_text.sub!(
        /buildConfigurationList = #{stale_list_id}\b[^;]*;/,
        "buildConfigurationList = #{shared_list.uuid} /* shared shipping configuration list */;"
      )
      raise 'missing local dependency' unless target_text.sub!(
        /#{stale_dependency.uuid}\b[^,]*,/,
        "#{shared_dependency.uuid} /* shared shipping dependency/proxy */,"
      )
      pbxproj[target_start..target_end] = target_text
      File.write(pbxproj_path, pbxproj)

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_tests = mutated.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      assert_empty shared_phases.map(&:uuid) - mutated_tests.build_phases.map(&:uuid)
      assert_equal shared_list.uuid, mutated_tests.build_configuration_list.uuid
      assert_includes mutated_tests.dependencies.map(&:uuid), shared_dependency.uuid
      run_reconciler(temporary_project, 'shared XCTest phase/configuration/dependency')

      reconciled = Xcodeproj::Project.open(temporary_project)
      repaired_tests = reconciled.targets.find { |target| target.name == 'ColumbaModelBAppTests' }
      repaired_shipping = reconciled.targets.find { |target| target.name == 'ColumbaAppTests' }
      assert_equal shipping_before, target_graph_signature(repaired_shipping)
      assert_equal shipping_app_before, target_graph_signature(
        reconciled.targets.find { |target| target.name == 'ColumbaApp' }
      )
      assert_empty shared_phases.map(&:uuid) & repaired_tests.build_phases.map(&:uuid)
      refute_equal shared_list.uuid, repaired_tests.build_configuration_list.uuid
      refute_includes repaired_tests.dependencies.map(&:uuid), shared_dependency.uuid
      assert_empty ([stale_list_id] + stale_dependency_ids) & reconciled.objects_by_uuid.keys
      assert repaired_tests.build_phases.all? { |phase|
        reconciled.targets.count { |target| target.build_phases.any? { |candidate| candidate.uuid == phase.uuid } } == 1
      }
      assert_second_run_byte_idempotent(temporary_project)
    end
  end

  def test_shipping_test_sources_do_not_reference_declarations_absent_from_shipping
    failures = source_paths(@shipping_tests).each_with_object({}) do |relative_path, references|
      source = File.read(File.join(REPOSITORY_ROOT, relative_path))
      matches = MODEL_B_DECLARATIONS_ABSENT_FROM_SHIPPING.select do |declaration|
        source.match?(/\b#{Regexp.escape(declaration)}\b/)
      end
      references[relative_path] = matches unless matches.empty?
    end
    assert_equal({}, failures)
  end

  def test_reconciler_removes_local_and_shared_model_b_test_build_files_ownership_safely
    Dir.mktmpdir('columba-modelb-test-membership') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      tests = fixture.targets.find { |target| target.name == 'ColumbaAppTests' }
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      extension = fixture.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      references = MODEL_B_ONLY_TEST_SOURCE_PATHS.to_h do |path|
        basename = File.basename(path)
        reference = fixture.files.find { |candidate| candidate.path == basename }
        [path, reference || raise("missing retained file reference for #{path}")]
      end

      local_ids = MODEL_B_ONLY_TEST_SOURCE_PATHS.map do |path|
        build_file = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
        build_file.file_ref = references.fetch(path)
        tests.source_build_phase.files << build_file
        build_file.uuid
      end
      shared_app_file = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
      shared_app_file.file_ref = references.fetch(MODEL_B_ONLY_TEST_SOURCE_PATHS.first)
      shipping.source_build_phase.files << shared_app_file
      shared_extension_file = fixture.new(Xcodeproj::Project::Object::PBXBuildFile)
      shared_extension_file.file_ref = references.fetch(MODEL_B_ONLY_TEST_SOURCE_PATHS.last)
      extension.source_build_phase.files << shared_extension_file
      fixture.save

      # xcodeproj cannot serialize one PBXBuildFile under two phases. Inject the
      # malformed test-phase references after saving the otherwise-valid graph.
      pbxproj_path = File.join(temporary_project, 'project.pbxproj')
      pbxproj = File.read(pbxproj_path)
      phase_header = "\t\t#{tests.source_build_phase.uuid} /* Sources */ = {"
      phase_start = pbxproj.index(phase_header) or raise 'missing test Sources phase in fixture'
      files_start = pbxproj.index("\t\t\tfiles = (\n", phase_start) or raise 'missing test Sources files'
      insertion_point = files_start + "\t\t\tfiles = (\n".length
      shared_entries = [shared_app_file, shared_extension_file].map do |build_file|
        "\t\t\t\t#{build_file.uuid} /* malformed shared Model B test source */,\n"
      end.join
      pbxproj.insert(insertion_point, shared_entries)
      File.write(pbxproj_path, pbxproj)

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_tests = mutated.targets.find { |target| target.name == 'ColumbaAppTests' }
      assert_equal 2, MODEL_B_ONLY_TEST_SOURCE_PATHS.count { |path|
        source_paths(mutated_tests, directory).include?(path)
      }
      assert_empty local_ids - mutated_tests.source_build_phase.files.map(&:uuid)
      shared_ids = [shared_app_file.uuid, shared_extension_file.uuid]
      assert_empty shared_ids - mutated_tests.source_build_phase.files.map(&:uuid)
      shipping_before = target_graph_signature(
        mutated.targets.find { |target| target.name == 'ColumbaApp' }
      )
      extension_before = target_graph_signature(
        mutated.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      )

      run_reconciler(temporary_project, 'Model B test membership')
      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_tests = reconciled.targets.find { |target| target.name == 'ColumbaAppTests' }
      assert_empty MODEL_B_ONLY_TEST_SOURCE_PATHS & source_paths(reconciled_tests, directory)
      assert_equal SHIPPING_TEST_SOURCE_PATHS, source_paths(reconciled_tests, directory)
      assert_equal shipping_before, target_graph_signature(
        reconciled.targets.find { |target| target.name == 'ColumbaApp' }
      ), 'test membership repair mutated the protected shipping app graph'
      assert_equal extension_before, target_graph_signature(
        reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      ), 'test membership repair mutated the protected extension graph'
      assert_empty local_ids & reconciled.objects_by_uuid.keys,
                   'target-local excluded test PBXBuildFiles became orphans'
      shared_ids.each do |uuid|
        assert reconciled.objects_by_uuid.key?(uuid), 'shared protected PBXBuildFile was deleted'
      end
      build_file_owners = Hash.new { |hash, key| hash[key] = [] }
      reconciled.objects.each do |object|
        next unless object.respond_to?(:files)

        object.files.each { |build_file| build_file_owners[build_file.uuid] << object.uuid }
      end
      all_build_file_ids = reconciled.objects.select do |object|
        object.is_a?(Xcodeproj::Project::Object::PBXBuildFile)
      end.map(&:uuid)
      assert_empty all_build_file_ids.reject { |uuid| build_file_owners.fetch(uuid, []).one? },
                   'reconciled project contains orphan or shared PBXBuildFiles'
      assert_second_run_byte_idempotent(temporary_project)
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
      shipping_dependency = shipping.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      refute_nil shipping_dependency
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
      shared_dependency = mutated_shipping.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      shared_id = shared_dependency.uuid
      assert_includes mutated_model_b.package_product_dependencies.map(&:uuid), shared_id
      assert(mutated_model_b.frameworks_build_phase.files.any? do |build_file|
        build_file.product_ref&.uuid == shared_id
      end)
      extension_before = target_graph_signature(
        mutated.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      )

      run_reconciler(temporary_project, 'shared-shipping-package')

      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_shipping = reconciled.targets.find { |target| target.name == 'ColumbaApp' }
      reconciled_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      reconciled_extension = reconciled.targets.find { |target| target.name == 'ColumbaNetworkExtension' }
      assert_equal extension_before, target_graph_signature(reconciled_extension),
                   'Reticulum package repair mutated the protected extension graph'
      shipping_local = reconciled_shipping.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      local = reconciled_model_b.package_product_dependencies.find do |dependency|
        dependency.product_name == 'ReticulumSwift'
      end
      refute_nil shipping_local
      refute_nil local
      refute_equal shared_id, shipping_local.uuid
      assert_equal shared_id, local.uuid,
                   'the formerly shared Reticulum dependency was not safely retained by Model B'
      refute_equal shipping_local.uuid, local.uuid
      assert_equal shipping_local.package.uuid, local.package.uuid
      assert(reconciled_shipping.frameworks_build_phase.files.any? do |build_file|
        build_file.product_ref&.uuid == shipping_local.uuid
      end)
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

  def test_duplicate_model_b_test_cleanup_preserves_shared_shipping_dependency_and_proxy
    Dir.mktmpdir('columba-duplicate-modelb-test-dependency') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)

      fixture = Xcodeproj::Project.open(temporary_project)
      shipping = fixture.targets.find { |target| target.name == 'ColumbaApp' }
      shipping_tests = fixture.targets.find { |target| target.name == 'ColumbaAppTests' }
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      duplicate = fixture.new_target(:unit_test_bundle, 'ColumbaModelBAppTests', :ios, nil)
      duplicate.add_dependency(model_b)
      model_b.add_dependency(duplicate)
      inbound = model_b.dependencies.find { |dependency| dependency.target&.uuid == duplicate.uuid }
      shipping_dependency = shipping_tests.dependencies.find do |dependency|
        dependency.target&.uuid == shipping.uuid
      end or raise 'shipping tests lack their protected host dependency'
      duplicate_id = duplicate.uuid
      duplicate_product_id = duplicate.product_reference.uuid
      shipping_dependency_id = shipping_dependency.uuid
      shipping_proxy_id = shipping_dependency.target_proxy.uuid
      inbound_ids = [inbound.uuid, inbound.target_proxy.uuid]
      duplicate_local_dependency = duplicate.dependencies.find do |dependency|
        dependency.target&.uuid == model_b.uuid
      end
      duplicate_local_ids = [duplicate_local_dependency.uuid, duplicate_local_dependency.target_proxy.uuid]
      duplicate_graph_ids = duplicate.build_phases.flat_map do |phase|
        [phase.uuid] + phase.files.map(&:uuid)
      end + duplicate.build_configurations.map(&:uuid) +
        [duplicate.build_configuration_list.uuid, duplicate_product_id] + duplicate_local_ids + inbound_ids
      fixture.save

      # xcodeproj cannot serialize one PBXTargetDependency under multiple
      # targets. Inject both the protected outbound edge and a two-owner inbound
      # edge after saving the otherwise-valid duplicate target graph.
      pbxproj_path = File.join(temporary_project, 'project.pbxproj')
      pbxproj = File.read(pbxproj_path)
      target_header = "\t\t#{duplicate_id} /* ColumbaModelBAppTests */ = {"
      target_start = pbxproj.index(target_header) or raise 'missing duplicate Model B XCTest target'
      target_end = pbxproj.index("\t\t};", target_start) or raise 'unterminated duplicate Model B XCTest target'
      target_text = pbxproj[target_start..target_end]
      dependency_entries = [
        "\t\t\t\t#{shipping_dependency_id} /* protected shipping host dependency */,\n",
        "\t\t\t\t#{inbound.uuid} /* shared inbound duplicate dependency */,\n"
      ].join
      raise 'missing duplicate dependency list' unless target_text.sub!(
        /dependencies = \(\n/, "dependencies = (\n#{dependency_entries}"
      )
      pbxproj[target_start..target_end] = target_text
      File.write(pbxproj_path, pbxproj)

      mutated = Xcodeproj::Project.open(temporary_project)
      mutated_shipping_tests = mutated.targets.find { |target| target.name == 'ColumbaAppTests' }
      mutated_duplicate = mutated.targets.find do |target|
        target.uuid == duplicate_id && target.name == 'ColumbaModelBAppTests'
      end
      refute_nil mutated_duplicate
      assert_includes mutated_duplicate.dependencies.map(&:uuid), shipping_dependency_id,
                      'shared shipping dependency mutation did not survive reopen'
      assert_includes mutated_duplicate.dependencies.map(&:uuid), inbound.uuid,
                      'shared inbound dependency mutation did not survive reopen'
      inbound_owners = mutated.targets.select do |target|
        target.dependencies.any? { |dependency| dependency.uuid == inbound.uuid }
      end
      assert_equal [model_b.uuid, duplicate_id].sort, inbound_owners.map(&:uuid).sort
      shipping_before = target_graph_signature(mutated_shipping_tests)

      run_reconciler(temporary_project, 'duplicate Model B XCTest shared dependency/proxy')

      reconciled = Xcodeproj::Project.open(temporary_project)
      repaired_shipping_tests = reconciled.targets.find { |target| target.name == 'ColumbaAppTests' }
      assert_equal shipping_before, target_graph_signature(repaired_shipping_tests),
                   'duplicate XCTest cleanup mutated the protected shipping test graph'
      protected_dependency = repaired_shipping_tests.dependencies.find do |dependency|
        dependency.uuid == shipping_dependency_id
      end
      refute_nil protected_dependency
      assert_equal shipping_proxy_id, protected_dependency.target_proxy&.uuid
      assert reconciled.objects_by_uuid.key?(shipping_dependency_id)
      assert reconciled.objects_by_uuid.key?(shipping_proxy_id)

      repaired_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      repaired_model_b_tests = reconciled.targets.select do |target|
        target.name == 'ColumbaModelBAppTests'
      end
      assert_equal 1, repaired_model_b_tests.size
      assert_equal [repaired_model_b.uuid],
                   repaired_model_b_tests.first.dependencies.map { |dependency| dependency.target&.uuid }
      refute_includes repaired_model_b_tests.first.dependencies.map(&:uuid), shipping_dependency_id
      refute reconciled.objects_by_uuid.key?(duplicate_id)
      assert_empty duplicate_graph_ids & reconciled.objects_by_uuid.keys,
                   'duplicate XCTest target left dependency/proxy or target graph orphans'

      dependency_owners = Hash.new { |hash, key| hash[key] = [] }
      reconciled.targets.each do |target|
        target.dependencies.each { |dependency| dependency_owners[dependency.uuid] << target.uuid }
      end
      all_dependencies = reconciled.objects.select do |object|
        object.is_a?(Xcodeproj::Project::Object::PBXTargetDependency)
      end
      assert all_dependencies.all? { |dependency| dependency_owners.fetch(dependency.uuid, []).one? },
             'reconciled project contains an orphan or shared target dependency'
      proxy_users = Hash.new { |hash, key| hash[key] = [] }
      all_dependencies.each do |dependency|
        proxy_users[dependency.target_proxy.uuid] << dependency.uuid if dependency.target_proxy
      end
      all_proxies = reconciled.objects.select do |object|
        object.is_a?(Xcodeproj::Project::Object::PBXContainerItemProxy)
      end
      assert all_proxies.all? { |proxy| proxy_users.fetch(proxy.uuid, []).one? },
             'reconciled project contains an orphan or shared dependency proxy'
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

  def test_reconciler_authoritatively_repairs_model_b_shared_feature_mapping
    Dir.mktmpdir('columba-modelb-shared-features') do |directory|
      temporary_project = File.join(directory, 'Columba.xcodeproj')
      FileUtils.cp_r(PROJECT_PATH, temporary_project)
      fixture = Xcodeproj::Project.open(temporary_project)
      model_b = fixture.targets.find { |target| target.name == 'ColumbaModelBApp' }
      debug = model_b.build_configurations.find { |configuration| configuration.name == 'Debug' }
      debug.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
        (compilation_tokens(debug) - [ONBOARDING_FLAG, MIGRATION_FLAG] + ['UNRELATED_MODEL_B_CONDITION']).uniq.join(' ')
      fixture.save

      run_reconciler(temporary_project, 'onboarding-mapping')
      reconciled = Xcodeproj::Project.open(temporary_project)
      reconciled_model_b = reconciled.targets.find { |target| target.name == 'ColumbaModelBApp' }
      reconciled_model_b.build_configurations.each do |configuration|
        tokens = compilation_tokens(configuration)
        assert_includes tokens, ONBOARDING_FLAG, configuration.name
        assert_includes tokens, MIGRATION_FLAG, configuration.name
      end
      assert_includes compilation_tokens(
        reconciled_model_b.build_configurations.find { |configuration| configuration.name == 'Debug' }
      ), 'UNRELATED_MODEL_B_CONDITION'
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
        configuration = target.build_configurations.find { |candidate| candidate.name == 'Debug' }
        tokens = compilation_tokens(configuration)
        configuration.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
          (tokens - [ONBOARDING_FLAG, RNODE_FLAG] + ['GENUINE_SHIPPING_CONDITION']).uniq.join(' ')
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
        configuration = target.build_configurations.find { |candidate| candidate.name == 'Debug' }
        assert_includes compilation_tokens(configuration), ONBOARDING_FLAG
        assert_includes compilation_tokens(configuration), RNODE_FLAG
        assert_includes compilation_tokens(configuration), 'GENUINE_SHIPPING_CONDITION'
      end
      assert_includes compilation_tokens(
        reconciled_model_b.build_configurations.find { |candidate| candidate.name == 'Debug' }
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
