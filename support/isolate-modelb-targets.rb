#!/usr/bin/env ruby
# frozen_string_literal: true

# Authoritatively split the Model B host from the shipping Python host.
#
# Shared app content is cloned from ColumbaApp, then the explicit Model B source
# additions below are reconciled onto ColumbaModelBApp. ReticulumSwift remains a
# direct, target-local link dependency in both apps: shipping's retained
# LXMFSwift/MessageRepository path exposes ReticulumSwift.Identity metadata even
# though its selected runtime is Python. Shipping
# exclusions are repaired first, so a stale project cannot leak those additions
# back through the clone operation.

require 'fileutils'
require 'fiddle'
require 'securerandom'
require 'xcodeproj'

SOURCE_PROJECT_PATH = File.expand_path(
  ENV.fetch('COLUMBA_PROJECT_PATH', File.expand_path('../Columba.xcodeproj', __dir__))
)
abort "Missing project at #{SOURCE_PROJECT_PATH}" unless File.directory?(SOURCE_PROJECT_PATH)

# Reconcile a same-filesystem staged copy and publish it only after every graph
# reopen succeeds. This keeps the authoritative project byte-for-byte unchanged
# when any prerequisite or final invariant fails, including failures after the
# structural localization save/reopen required by Xcodeproj.
STAGING_ROOT = File.join(
  File.dirname(SOURCE_PROJECT_PATH),
  ".columba-project-stage-#{SecureRandom.hex(6)}"
)
PROJECT_PATH = File.join(STAGING_ROOT, File.basename(SOURCE_PROJECT_PATH))
FileUtils.mkdir_p(STAGING_ROOT)
FileUtils.cp_r(SOURCE_PROJECT_PATH, PROJECT_PATH)
at_exit { FileUtils.rm_rf(STAGING_ROOT) if File.exist?(STAGING_ROOT) }
SHIPPING_TARGET_NAME = 'ColumbaApp'
SHIPPING_TEST_TARGET_NAME = 'ColumbaAppTests'
MODEL_B_TARGET_NAME = 'ColumbaModelBApp'
MODEL_B_TEST_TARGET_NAME = 'ColumbaModelBAppTests'
EXTENSION_TARGET_NAME = 'ColumbaNetworkExtension'
LEGACY_SWIFT_CONFIGURATION_NAMES = %w[Debug-Swift Release-Swift].freeze
SHIPPING_ENTITLEMENTS = 'Sources/ColumbaApp/Resources/ColumbaApp.entitlements'
MODEL_B_ENTITLEMENTS = 'Sources/ColumbaApp/Resources/ColumbaModelBApp.entitlements'
CANONICAL_FLAGS = %w[
  COLUMBA_RUNTIME_PYTHON
  COLUMBA_RUNTIME_MODEL_B
  ENABLE_NETWORK_EXTENSION
  COLUMBA_BACKEND_SWIFT
].freeze
ONBOARDING_FLAG = 'COLUMBA_ONBOARDING_ENABLED'
MIGRATION_FLAG = 'COLUMBA_MIGRATION_ENABLED'
SHARED_APP_FLAGS = [ONBOARDING_FLAG, MIGRATION_FLAG].freeze
SHIPPING_FORBIDDEN_FLAGS = CANONICAL_FLAGS
MODEL_B_FLAGS = %w[
  COLUMBA_RUNTIME_MODEL_B
  ENABLE_NETWORK_EXTENSION
  COLUMBA_BACKEND_SWIFT
].freeze
RETICULUM_PRODUCT_NAME = 'ReticulumSwift'
RETICULUM_PACKAGE_IDENTITY = 'reticulum-swift'
RETICULUM_REPOSITORY_URL = 'https://github.com/torlando-tech/reticulum-swift.git'
EMPTY_SOURCE_BUILD_FILE_METADATA = {
  settings: nil,
  platform_filter: nil,
  platform_filters: nil
}.freeze
MODEL_B_ONLY_SOURCE_METADATA = {
  'Sources/RNSBackendProxy/ProxyRnsBackend.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Services/TunnelManager.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Services/ExtensionFrameReader.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Services/ModelBBLEService.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Views/Settings/BackgroundTransportView.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Views/Components/BackgroundVPNExplainer.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Views/Onboarding/BackgroundDeliveryGateView.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Views/Onboarding/BackgroundDeliveryPage.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/AppGroupBridgeInterface.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/AppGroupBLEDriver.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/AppGroupBLESeamTransport.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/AppGroupBLEServer.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/BLEDriverSeam.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/ProxyIPC.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/OutboxQueue.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Services/ModelBRNodeService.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/AppGroupRNodeSeamTransport.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/AppGroupRNodeSeamWire.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/AppGroupRNodeServer.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/RNodeSeam.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/PropagationSeam.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/RNSBackendSwift/SwiftRNSBackend.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/Shared/NomadNetFetch.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Services/ModelBInboundReplay.swift' => {
    settings: nil,
    platform_filter: 'ios',
    platform_filters: nil
  }.freeze
}.freeze
MODEL_B_ONLY_SOURCE_PATHS = MODEL_B_ONLY_SOURCE_METADATA.keys.freeze
PYTHON_ONLY_SOURCE_METADATA = {
  'Sources/ColumbaApp/Python/Models/PyAnnounce.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Python/Models/PyMessage.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Python/Models/PyConversation.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Python/Models/PyLocalIdentity.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/PythonBridge/PythonBridge.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/PythonBridge/PythonRuntime.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/RNSBackendPy/PythonRNSBackend.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/ColumbaApp/Services/PythonNetworkTransport.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/PythonBridge/PythonBLECallbackBridge.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA,
  'Sources/PythonBridge/PythonRNodeBLEBridge.swift' => EMPTY_SOURCE_BUILD_FILE_METADATA
}.freeze
PYTHON_ONLY_SOURCE_PATHS = PYTHON_ONLY_SOURCE_METADATA.keys.freeze
PYTHON_SOURCE_REFERENCES_TO_CREATE = %w[
  Sources/PythonBridge/PythonRNodeBLEBridge.swift
].freeze
# PythonConfigWriter.swift intentionally remains shared. It is a pure config-text
# formatter with no CPython/Python.h dependency; shipping AppServices writes the
# embedded runtime's config while Model B's SwiftRNSBackend reuses its stable
# section naming. Keeping the formatter does not retain any Python source,
# framework, resource, packaging phase, or bridging header in Model B.
PYTHON_SOURCE_PREDECESSORS = {
  'Sources/ColumbaApp/Python/Models/PyAnnounce.swift' =>
    'Sources/ColumbaApp/Views/NomadNet/ZoomableScrollView.swift',
  'Sources/ColumbaApp/Python/Models/PyMessage.swift' =>
    'Sources/ColumbaApp/Python/Models/PyAnnounce.swift',
  'Sources/ColumbaApp/Python/Models/PyConversation.swift' =>
    'Sources/ColumbaApp/Python/Models/PyMessage.swift',
  'Sources/ColumbaApp/Python/Models/PyLocalIdentity.swift' =>
    'Sources/ColumbaApp/Python/Models/PyConversation.swift',
  'Sources/PythonBridge/PythonBridge.swift' =>
    'Sources/ColumbaApp/Python/Models/PyLocalIdentity.swift',
  'Sources/PythonBridge/PythonRuntime.swift' => 'Sources/PythonBridge/PythonBridge.swift',
  'Sources/RNSBackendPy/PythonRNSBackend.swift' => 'Sources/PythonBridge/PythonRuntime.swift',
  'Sources/ColumbaApp/Services/PythonNetworkTransport.swift' =>
    'Sources/ColumbaApp/Services/CallManager.swift',
  'Sources/PythonBridge/PythonBLECallbackBridge.swift' =>
    'Sources/ColumbaApp/Models/CodecProfileInfo.swift',
  'Sources/PythonBridge/PythonRNodeBLEBridge.swift' =>
    'Sources/PythonBridge/PythonBLECallbackBridge.swift'
}.freeze
PYTHON_FRAMEWORK_PATH = 'Frameworks/Python.xcframework'
PYTHON_RESOURCE_PATH = 'app'
PYTHON_BRIDGING_HEADER = 'Sources/PythonBridge/ColumbaPython-Bridging-Header.h'
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
# These seam tests belong only to the explicit Model B XCTest host. Shipping's
# XCTest target cannot compile declarations intentionally absent from its app.
MODEL_B_ONLY_TEST_SOURCE_PATHS = %w[
  Tests/ColumbaAppTests/BLESeamDriverTests.swift
  Tests/ColumbaAppTests/RNodeSeamTests.swift
].freeze

module ModelBTargetIsolation
  module_function

  # Model B is an explicit target/scheme, never a build-configuration variant.
  # Remove the retired configuration names from every owner before using
  # shipping as the source for any regenerated target configuration list.
  def remove_legacy_swift_configurations(project)
    owners = [project] + project.targets
    removed = []
    owners.each do |owner|
      list = owner.build_configuration_list
      list.build_configurations.to_a.each do |configuration|
        next unless LEGACY_SWIFT_CONFIGURATION_NAMES.include?(configuration.name)

        index = list.build_configurations.each_with_index.find do |candidate, _position|
          candidate.uuid == configuration.uuid
        end&.last
        list.build_configurations.delete_at(index) if index
        removed << configuration
      end
    end
    removed.uniq { |configuration| configuration.uuid }.each do |configuration|
      still_owned = owners.any? do |owner|
        owner.build_configuration_list.build_configurations.any? do |candidate|
          candidate.uuid == configuration.uuid
        end
      end
      configuration.remove_from_project unless still_owned
    end
  end

  def duplicate_value(value)
    Marshal.load(Marshal.dump(value))
  end

  def compilation_tokens(configuration)
    value = configuration.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']
    Array(value).flat_map { |entry| entry.to_s.split }.uniq
  end

  def set_compilation_tokens(configuration, required, removed: CANONICAL_FLAGS)
    tokens = compilation_tokens(configuration).reject { |token| removed.include?(token) }
    required.each { |token| tokens << token unless tokens.include?(token) }
    configuration.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = tokens.join(' ')
  end

  def extension_embed_phase?(phase)
    phase.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) &&
      (phase.name == 'Embed App Extensions' || phase.symbol_dst_subfolder_spec == :plug_ins)
  end

  def remove_build_file(build_file)
    build_file.remove_from_project
  end

  def remove_phase(phase)
    phase.files.dup.each { |build_file| remove_build_file(build_file) }
    phase.remove_from_project
  end

  def remove_dependency(dependency)
    proxy = dependency.target_proxy
    dependency.remove_from_project
    proxy.remove_from_project if proxy && proxy.referrers.empty?
  end

  def dependency_owners(project, dependency)
    project.targets.select do |target|
      target.dependencies.any? { |candidate| candidate.uuid == dependency.uuid }
    end
  end

  def proxy_users(project, proxy)
    return [] unless proxy

    project.objects.select do |object|
      object.is_a?(Xcodeproj::Project::Object::PBXTargetDependency) &&
        object.target_proxy&.uuid == proxy.uuid
    end
  end

  def detach_dependency(project, target, dependency)
    proxy = dependency.target_proxy
    index = target.dependencies.index { |candidate| candidate.uuid == dependency.uuid }
    target.dependencies.delete_at(index) if index
    if dependency_owners(project, dependency).empty?
      dependency.remove_from_project
      proxy.remove_from_project if proxy && proxy_users(project, proxy).empty?
    end
  end

  def phase_owners(project, phase)
    project.targets.select do |target|
      target.build_phases.any? { |candidate| candidate.uuid == phase.uuid }
    end
  end

  def build_file_owners(project, build_file)
    project.objects.select do |object|
      object.respond_to?(:files) && object.files.any? do |candidate|
        candidate && candidate.uuid == build_file.uuid
      end
    end
  end

  def copy_simple_attributes(source, destination)
    source.class.simple_attributes.each do |attribute|
      destination.public_send(
        "#{attribute.name}=", duplicate_value(source.public_send(attribute.name))
      )
    end
  end

  def clone_build_file(project, source)
    destination = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    copy_simple_attributes(source, destination)
    destination.file_ref = source.file_ref
    destination.product_ref = source.product_ref
    destination
  end

  def configuration_list_owners(project, list)
    owners = project.targets.select do |target|
      target.build_configuration_list&.uuid == list.uuid
    end
    owners << project.root_object if project.root_object.build_configuration_list&.uuid == list.uuid
    owners
  end

  def configuration_owners(project, configuration)
    project.objects.select do |object|
      object.is_a?(Xcodeproj::Project::Object::XCConfigurationList) &&
        object.build_configurations.any? { |candidate| candidate.uuid == configuration.uuid }
    end
  end

  def clone_configuration(project, source)
    destination = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
    copy_simple_attributes(source, destination)
    destination.base_configuration_reference = source.base_configuration_reference
    destination
  end

  def localize_test_configurations(project, target)
    source_list = target.build_configuration_list
    list_is_local = configuration_list_owners(project, source_list).map(&:uuid) == [target.uuid]
    configurations_are_local = source_list.build_configurations.all? do |configuration|
      configuration_owners(project, configuration).map(&:uuid) == [source_list.uuid]
    end
    return source_list if list_is_local && configurations_are_local

    destination = project.new(Xcodeproj::Project::Object::XCConfigurationList)
    copy_simple_attributes(source_list, destination)
    source_list.build_configurations.each do |configuration|
      destination.build_configurations << clone_configuration(project, configuration)
    end
    target.build_configuration_list = destination
    if configuration_list_owners(project, source_list).empty?
      source_list.build_configurations.to_a.each do |configuration|
        source_list.build_configurations.delete_if { |candidate| candidate.uuid == configuration.uuid }
        configuration.remove_from_project if configuration_owners(project, configuration).empty?
      end
      source_list.remove_from_project
    end
    destination
  end

  def localize_test_phases(project, target)
    target.build_phases.to_a.each do |phase|
      owners = phase_owners(project, phase)
      if owners.any? { |owner| owner.uuid != target.uuid }
        # A protected target remains authoritative for a shared phase. Detach
        # only the malformed XCTest edge; the exact local phase is retained (or
        # recreated below) and reconciled from the authoritative test matrix.
        index = target.build_phases.index { |candidate| candidate.uuid == phase.uuid }
        target.build_phases.delete_at(index) if index
        next
      end

      phase.files.compact.to_a.each do |build_file|
        next if build_file_owners(project, build_file).map(&:uuid) == [phase.uuid]

        replacement = clone_build_file(project, build_file)
        index = phase.files.index { |candidate| candidate.uuid == build_file.uuid }
        next unless index

        phase.files.delete_at(index)
        phase.files.insert(index, replacement)
      end
    end
  end

  def product_owners(project, product)
    project.targets.select do |target|
      target.product_reference&.uuid == product.uuid
    end
  end

  def product_build_file_users(project, product)
    project.objects.select do |object|
      object.is_a?(Xcodeproj::Project::Object::PBXBuildFile) &&
        object.file_ref&.uuid == product.uuid
    end
  end

  def localize_test_product(project, target, template)
    current = target.product_reference
    return current if current && product_owners(project, current).map(&:uuid) == [target.uuid]

    product = project.new(Xcodeproj::Project::Object::PBXFileReference)
    copy_simple_attributes(template || current, product)
    # Give the replacement semantic identity before assigning it. Otherwise
    # xcodeproj can suppress the association as equal to the shared product.
    product.path = "__local_#{product.uuid}.xctest"
    product.explicit_file_type = 'wrapper.cfbundle'
    product.source_tree = 'BUILT_PRODUCTS_DIR'
    project.products_group.children << product
    target.product_reference = product
    product
  end

  def clean_test_products(project, retained)
    project.products_group.children.to_a.each do |product|
      next if product.uuid == retained.uuid
      next unless product.path == "#{MODEL_B_TEST_TARGET_NAME}.xctest"

      if product_owners(project, product).empty? && product_build_file_users(project, product).empty?
        product.path = "__stale_#{product.uuid}.xctest"
        product.remove_from_project
      else
        product.path = "__protected_#{product.uuid}.xctest"
      end
    end
  end

  def clean_orphan_graph_nodes(project)
    project.objects.select do |object|
      object.is_a?(Xcodeproj::Project::Object::AbstractBuildPhase) && phase_owners(project, object).empty?
    end.each do |phase|
      phase.files.compact.dup.each { |build_file| remove_build_file_from_phase(project, phase, build_file) }
      phase.remove_from_project
    end

    project.objects.select do |object|
      object.is_a?(Xcodeproj::Project::Object::XCConfigurationList) &&
        configuration_list_owners(project, object).empty?
    end.each do |list|
      list.build_configurations.to_a.each do |configuration|
        list.build_configurations.delete_if { |candidate| candidate.uuid == configuration.uuid }
        configuration.remove_from_project if configuration_owners(project, configuration).empty?
      end
      list.remove_from_project
    end

    project.objects.select do |object|
      object.is_a?(Xcodeproj::Project::Object::PBXTargetDependency) &&
        dependency_owners(project, object).empty?
    end.each do |dependency|
      proxy = dependency.target_proxy
      dependency.remove_from_project
      proxy.remove_from_project if proxy && proxy_users(project, proxy).empty?
    end
    project.objects.select do |object|
      object.is_a?(Xcodeproj::Project::Object::PBXContainerItemProxy) && proxy_users(project, object).empty?
    end.each(&:remove_from_project)
  end

  def authoritative_shipping_build_file?(project, shipping, phase, build_file)
    if build_file.product_ref
      return shipping.package_product_dependencies.any? do |dependency|
        dependency.uuid == build_file.product_ref.uuid
      end && build_file_metadata(build_file) == EMPTY_SOURCE_BUILD_FILE_METADATA
    end
    return false unless build_file.file_ref

    path = source_path(project, build_file.file_ref)
    expected_metadata = if phase.is_a?(Xcodeproj::Project::Object::PBXSourcesBuildPhase) &&
                           PYTHON_ONLY_SOURCE_METADATA.key?(path)
                          PYTHON_ONLY_SOURCE_METADATA.fetch(path)
                        elsif phase.is_a?(Xcodeproj::Project::Object::PBXFrameworksBuildPhase) &&
                              build_file.file_ref.display_name == File.basename(PYTHON_FRAMEWORK_PATH)
                          EMPTY_SOURCE_BUILD_FILE_METADATA
                        elsif phase.is_a?(Xcodeproj::Project::Object::PBXResourcesBuildPhase) &&
                              build_file.file_ref.display_name == File.basename(PYTHON_RESOURCE_PATH)
                          EMPTY_SOURCE_BUILD_FILE_METADATA
                        end
    expected_metadata && build_file_metadata(build_file) == expected_metadata
  end

  # The canonical shipping phases are authoritative mutation points below. A
  # malformed project may also attach one of them to Model B, the extension,
  # tests, or several protected targets. Replace only shipping's ownership with
  # a phase and PBXBuildFiles that are genuinely local before changing Python
  # membership, metadata, or order. Detach the malformed extra ownership from
  # protected targets so their pre-mutation graph is restored.
  def localize_shipping_canonical_phases(project, shipping)
    localized = false
    model_b = project.targets.find { |target| target.name == MODEL_B_TARGET_NAME }
    model_b_tests = project.targets.find { |target| target.name == MODEL_B_TEST_TARGET_NAME }
    canonical_phases = [
      shipping.source_build_phase,
      shipping.frameworks_build_phase,
      shipping.resources_build_phase
    ]
    canonical_phases.each do |source|
      # Model B and its XCTest target are authoritatively regenerated later in
      # this script. Detach their malformed ownership first so the canonical
      # shipping phase and UUID stay stable when either is the only other owner.
      # Other owners are protected: shipping gets a local clone and their
      # malformed extra attachment is removed, restoring their pre-mutation graph.
      [model_b, model_b_tests].compact.each do |regenerated_target|
        shared_index = regenerated_target.build_phases.index do |phase|
          phase.uuid == source.uuid
        end
        regenerated_target.build_phases.delete_at(shared_index) if shared_index
      end
      # PBXBuildFiles are phase-owned. Even when the canonical shipping phase is
      # itself local, one of its build files may be independently referenced by
      # a protected target's phase in a malformed graph. Keep the shipping owner
      # and detach every foreign reference before the sole-owner fast path.
      source.files.compact.dup.each do |build_file|
        foreign_phases = build_file_owners(project, build_file).reject do |phase|
          phase.uuid == source.uuid
        end
        next if foreign_phases.empty?

        # A package build file referencing a dependency not owned by shipping is
        # unambiguously protected-origin contamination. Remove only shipping's
        # reference before Python framework ordering is reconciled.
        if build_file.product_ref && !shipping.package_product_dependencies.any? { |dependency|
             dependency.uuid == build_file.product_ref.uuid
           }
          index = source.files.index { |candidate| candidate&.uuid == build_file.uuid }
          source.files.delete_at(index) if index
          next
        end

        next unless authoritative_shipping_build_file?(project, shipping, source, build_file)

        # If shipping already has a distinct local build file for the same
        # reference, this shared object originated in a protected phase and was
        # injected into shipping. Remove only shipping's duplicate reference and
        # preserve the protected UUID/metadata. Without such a local sibling the
        # shared object is shipping's canonical owner, so remove foreign refs.
        local_sibling = source.files.compact.find do |candidate|
          next false if candidate.uuid == build_file.uuid

          same_reference = if build_file.product_ref
                             candidate.product_ref&.uuid == build_file.product_ref.uuid
                           else
                             candidate.file_ref&.uuid == build_file.file_ref&.uuid
                           end
          same_reference &&
            authoritative_shipping_build_file?(project, shipping, source, candidate) &&
            build_file_owners(project, candidate).map(&:uuid) == [source.uuid]
        end
        if local_sibling
          index = source.files.index { |candidate| candidate&.uuid == build_file.uuid }
          source.files.delete_at(index) if index
          next
        end

        foreign_phases.each do |object|
          (object.files.length - 1).downto(0) do |file_index|
            candidate = object.files[file_index]
            object.files.delete_at(file_index) if candidate&.uuid == build_file.uuid
          end
        end
      end
      next if phase_owners(project, source).map(&:uuid) == [shipping.uuid]

      index = shipping.build_phases.index { |phase| phase.uuid == source.uuid }
      raise "shipping canonical #{source.isa} phase is missing" unless index

      destination = project.new(source.class)
      copy_simple_attributes(source, destination)
      shipping.build_phases.delete_at(index)
      shipping.build_phases.insert(index, destination)
      source.files.compact.each do |build_file|
        destination.files << clone_build_file(project, build_file)
      end

      phase_owners(project, source).each do |owner|
        owner_index = owner.build_phases.index { |phase| phase.uuid == source.uuid }
        owner.build_phases.delete_at(owner_index) if owner_index
      end
      if phase_owners(project, source).empty?
        source.files.compact.dup.each do |build_file|
          remove_build_file_from_phase(project, source, build_file)
        end
        source.remove_from_project
      end
      localized = true
    end
    localized
  end

  def package_dependency_owners(project, dependency)
    project.targets.select do |target|
      target.package_product_dependencies.any? { |candidate| candidate.uuid == dependency.uuid }
    end
  end

  def package_dependency_build_file_users(project, dependency)
    project.objects.select do |object|
      object.is_a?(Xcodeproj::Project::Object::PBXBuildFile) &&
        object.product_ref&.uuid == dependency.uuid
    end
  end

  def package_dependency_reusable_for_target?(project, dependency, target)
    return false unless package_dependency_owners(project, dependency).map(&:uuid) == [target.uuid]

    package_dependency_build_file_users(project, dependency).none? do |build_file|
      build_file_owners(project, build_file).any? do |phase|
        phase_owners(project, phase).any? { |owner| owner.uuid != target.uuid }
      end
    end
  end

  def package_dependency_referenced?(project, dependency)
    package_dependency_owners(project, dependency).any? ||
      package_dependency_build_file_users(project, dependency).any?
  end

  def source_path(project, file_reference)
    absolute = Pathname.new(File.expand_path(file_reference.real_path.to_s, project.path.dirname.to_s))
    absolute.relative_path_from(Pathname.new(File.expand_path(project.path.dirname.to_s))).to_s
  end

  def model_b_source_references(project)
    references = project.files.to_h { |reference| [source_path(project, reference), reference] }
    MODEL_B_ONLY_SOURCE_PATHS.map do |path|
      references.fetch(path) { raise "Missing Model B source reference: #{path}" }
    end
  end

  def project_file_reference(project, path)
    project.files.find { |reference| source_path(project, reference) == path } or
      raise "Missing project file reference: #{path}"
  end

  def ensure_python_source_references(project)
    existing = project.files.to_h { |reference| [source_path(project, reference), reference] }
    missing = PYTHON_SOURCE_REFERENCES_TO_CREATE.reject { |path| existing.key?(path) }
    return if missing.empty?

    group = project.groups.find do |candidate|
      candidate.path.to_s == 'Sources/PythonBridge' || candidate.display_name == 'PythonBridge'
    end
    raise 'Missing PythonBridge project group' unless group

    missing.each { |path| group.new_file(File.basename(path)) }
  end

  def local_build_file_for_reference(project, phase, reference)
    matching = phase.files.select { |build_file| build_file.file_ref&.uuid == reference.uuid }
    retained = matching.find do |build_file|
      build_file_owners(project, build_file).map(&:uuid) == [phase.uuid]
    end
    retained ||= project.new(Xcodeproj::Project::Object::PBXBuildFile)
    matching.reject { |build_file| build_file.uuid == retained.uuid }.each do |build_file|
      remove_build_file_from_phase(project, phase, build_file)
    end
    retained.file_ref = reference
    retained.product_ref = nil
    phase.files << retained unless phase.files.any? { |build_file| build_file.uuid == retained.uuid }
    retained
  end

  def place_build_file_after(project, phase, build_file, predecessor_path)
    phase.files.delete(build_file)
    predecessor_index = phase.files.index do |candidate|
      candidate.file_ref && source_path(project, candidate.file_ref) == predecessor_path
    end
    raise "Missing authoritative predecessor #{predecessor_path}" unless predecessor_index

    phase.files.insert(predecessor_index + 1, build_file)
  end

  def place_build_file_at(phase, build_file, index)
    phase.files.delete(build_file)
    phase.files.insert(index, build_file)
  end

  def reconcile_shipping_python_sources(project, shipping)
    PYTHON_ONLY_SOURCE_PATHS.each do |path|
      reference = project_file_reference(project, path)
      build_file = local_build_file_for_reference(project, shipping.source_build_phase, reference)
      apply_build_file_metadata(build_file, PYTHON_ONLY_SOURCE_METADATA.fetch(path))
      place_build_file_after(
        project, shipping.source_build_phase, build_file, PYTHON_SOURCE_PREDECESSORS.fetch(path)
      )
    end
  end

  def reconcile_shipping_python_files(project, shipping)
    framework_reference = project_file_reference(project, PYTHON_FRAMEWORK_PATH)
    framework_file = local_build_file_for_reference(
      project, shipping.frameworks_build_phase, framework_reference
    )
    apply_build_file_metadata(framework_file, EMPTY_SOURCE_BUILD_FILE_METADATA)
    place_build_file_at(shipping.frameworks_build_phase, framework_file, 1)

    resource_reference = project_file_reference(project, PYTHON_RESOURCE_PATH)
    resource_file = local_build_file_for_reference(project, shipping.resources_build_phase, resource_reference)
    apply_build_file_metadata(resource_file, EMPTY_SOURCE_BUILD_FILE_METADATA)
    place_build_file_at(shipping.resources_build_phase, resource_file, 2)
  end

  def python_embed_phase?(phase)
    phase.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) &&
      phase.name == PYTHON_EMBED_PHASE_NAME
  end

  def python_install_phase?(phase)
    phase.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) &&
      phase.name == PYTHON_SHELL_PHASE_NAME
  end

  def reconcile_shipping_python_phases(project, shipping)
    embed_candidates = shipping.build_phases.select { |phase| python_embed_phase?(phase) }
    embed = embed_candidates.find do |phase|
      phase_owners(project, phase).map(&:uuid) == [shipping.uuid]
    end || project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
    embed_candidates.reject { |phase| phase.uuid == embed.uuid }.each do |phase|
      remove_phase_for_target(project, shipping, phase)
    end
    embed.name = PYTHON_EMBED_PHASE_NAME
    embed.dst_path = ''
    embed.dst_subfolder_spec = '10'
    embed.build_action_mask = '2147483647'
    embed.run_only_for_deployment_postprocessing = '0'
    framework_reference = project_file_reference(project, PYTHON_FRAMEWORK_PATH)
    embed_file = local_build_file_for_reference(project, embed, framework_reference)
    embed.files.dup.reject { |build_file| build_file.uuid == embed_file.uuid }.each do |build_file|
      remove_build_file_from_phase(project, embed, build_file)
    end
    apply_build_file_metadata(
      embed_file,
      settings: { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] },
      platform_filter: nil,
      platform_filters: nil
    )
    embed.files.clear
    embed.files << embed_file

    shell_candidates = shipping.build_phases.select { |phase| python_install_phase?(phase) }
    shell = shell_candidates.find do |phase|
      phase_owners(project, phase).map(&:uuid) == [shipping.uuid]
    end || project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
    shell_candidates.reject { |phase| phase.uuid == shell.uuid }.each do |phase|
      remove_phase_for_target(project, shipping, phase)
    end
    shell.name = PYTHON_SHELL_PHASE_NAME
    shell.shell_path = '/bin/sh'
    shell.shell_script = PYTHON_INSTALL_SCRIPT
    shell.input_paths = ['$(PROJECT_DIR)/Frameworks/Python.xcframework/build/utils.sh']
    shell.output_paths = []
    shell.input_file_list_paths = []
    shell.output_file_list_paths = []
    shell.always_out_of_date = '1'
    shell.show_env_vars_in_log = '0'
    shell.dependency_file = nil
    shell.build_action_mask = '2147483647'
    shell.run_only_for_deployment_postprocessing = '0'

    embed_index = shipping.build_phases.index { |phase| phase.uuid == embed.uuid }
    shipping.build_phases.delete_at(embed_index) if embed_index
    shell_index = shipping.build_phases.index { |phase| phase.uuid == shell.uuid }
    shipping.build_phases.delete_at(shell_index) if shell_index
    resources_index = shipping.build_phases.index do |phase|
      phase.uuid == shipping.resources_build_phase.uuid
    end
    raise 'shipping Resources phase is missing' unless resources_index

    shipping.build_phases.insert(resources_index + 1, embed)
    shipping.build_phases.insert(resources_index + 2, shell)
  end

  def root_reticulum_package_reference(project)
    project.root_object.package_references.find do |reference|
      next false unless reference.is_a?(
        Xcodeproj::Project::Object::XCRemoteSwiftPackageReference
      )

      repository_url = reference.repositoryURL.to_s
      identity = repository_url.sub(%r{/+\z}, '').sub(/\.git\z/i, '').split('/').last.to_s.downcase
      repository_url == RETICULUM_REPOSITORY_URL && identity == RETICULUM_PACKAGE_IDENTITY
    end
  end

  def strip_shipping_model_b_membership(project, shipping)
    shipping.source_build_phase.files.dup.each do |build_file|
      next unless MODEL_B_ONLY_SOURCE_PATHS.include?(source_path(project, build_file.file_ref))

      remove_build_file_from_phase(project, shipping.source_build_phase, build_file)
    end
  end

  def strip_shipping_model_b_test_membership(project, shipping_tests)
    shipping_tests.source_build_phase.files.dup.each do |build_file|
      next unless MODEL_B_ONLY_TEST_SOURCE_PATHS.include?(source_path(project, build_file.file_ref))

      remove_build_file_from_phase(project, shipping_tests.source_build_phase, build_file)
    end
  end

  # Reconcile a required package product as a genuinely target-local graph:
  # one XCSwiftPackageProductDependency owned by +target+ and one PBXBuildFile
  # owned by its Frameworks phase. Malformed shared objects are detached, never
  # globally deleted while another target/phase still references them.
  def reconcile_required_package_product(project, target, product_name, package)
    original = target.package_product_dependencies.to_a
    matching = original.select { |dependency| dependency.product_name == product_name }
    dependency = matching.find do |candidate|
      package_dependency_reusable_for_target?(project, candidate, target)
    end || project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dependency.product_name = product_name
    dependency.package = package

    ordered = []
    inserted = false
    original.each do |candidate|
      if candidate.product_name == product_name
        unless inserted
          ordered << dependency
          inserted = true
        end
      else
        ordered << candidate
      end
    end
    ordered << dependency unless inserted
    target.package_product_dependencies.clear
    ordered.each { |candidate| target.package_product_dependencies << candidate }

    framework_phase = target.frameworks_build_phase
    reusable_build_file = framework_phase.files.compact.find do |build_file|
      build_file.product_ref&.uuid == dependency.uuid &&
        build_file_owners(project, build_file).map(&:uuid) == [framework_phase.uuid]
    end
    target.build_phases.each do |phase|
      next unless phase.respond_to?(:files)

      phase.files.compact.dup.each do |build_file|
        next unless build_file.product_ref&.product_name == product_name
        next if build_file.uuid == reusable_build_file&.uuid && phase.uuid == framework_phase.uuid

        remove_build_file_from_phase(project, phase, build_file)
      end
    end
    build_file = reusable_build_file || project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.file_ref = nil
    build_file.product_ref = dependency
    apply_build_file_metadata(build_file, EMPTY_SOURCE_BUILD_FILE_METADATA)
    framework_phase.files << build_file unless framework_phase.files.compact.any? do |candidate|
      candidate.uuid == build_file.uuid
    end

    matching.reject { |candidate| candidate.uuid == dependency.uuid }.each do |stale|
      stale.remove_from_project unless package_dependency_referenced?(project, stale)
    end
    dependency
  end

  def remove_phase_for_target(project, target, phase)
    if phase_owners(project, phase).none? { |owner| owner.uuid != target.uuid }
      phase.files.dup.each do |build_file|
        remove_build_file_from_phase(project, phase, build_file)
      end
      phase.remove_from_project
    else
      target.build_phases.delete(phase)
    end
  end

  def remove_build_file_from_phase(project, phase, build_file)
    if build_file_owners(project, build_file).none? { |owner| owner.uuid != phase.uuid }
      remove_build_file(build_file)
    else
      phase.files.delete(build_file)
    end
  end

  def strip_shipping_extension_graph(project, shipping, extension)
    shipping.dependencies.dup.each do |dependency|
      remove_dependency(dependency) if dependency.target == extension
    end

    shipping.build_phases.dup.each do |phase|
      next unless phase.respond_to?(:files)

      # A malformed project can attach another target's embed phase to shipping.
      # Detach that phase without editing its files; the other owner must remain
      # byte-for-byte intact.
      if extension_embed_phase?(phase)
        remove_phase_for_target(project, shipping, phase)
        next
      end

      phase.files.dup.each do |build_file|
        next unless build_file.file_ref == extension.product_reference

        remove_build_file_from_phase(project, phase, build_file)
      end
    end
  end

  def phase_key(phase)
    [
      phase.class.name,
      phase.respond_to?(:name) ? phase.name.to_s : '',
      phase.respond_to?(:dst_subfolder_spec) ? phase.dst_subfolder_spec.to_s : ''
    ]
  end

  def copy_common_phase_attributes(source, destination)
    destination.build_action_mask = source.build_action_mask
    destination.run_only_for_deployment_postprocessing = source.run_only_for_deployment_postprocessing
    destination.always_out_of_date = source.always_out_of_date if source.respond_to?(:always_out_of_date)
    destination.comments = duplicate_value(source.comments) if source.respond_to?(:comments)

    if source.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
      destination.name = source.name
      destination.dst_path = source.dst_path
      destination.dst_subfolder_spec = source.dst_subfolder_spec
    elsif source.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
      destination.name = source.name
      destination.shell_path = source.shell_path
      destination.shell_script = source.shell_script
      destination.input_paths = duplicate_value(source.input_paths)
      destination.output_paths = duplicate_value(source.output_paths)
      destination.input_file_list_paths = duplicate_value(source.input_file_list_paths)
      destination.output_file_list_paths = duplicate_value(source.output_file_list_paths)
      destination.show_env_vars_in_log = source.show_env_vars_in_log
      destination.always_out_of_date = source.always_out_of_date
      destination.dependency_file = source.dependency_file
    end
  end

  def new_phase(project, source)
    project.new(source.class)
  end

  def reconcile_package_products(project, shipping, model_b)
    original = model_b.package_product_dependencies.to_a
    existing_by_name = original.select do |dependency|
      package_dependency_reusable_for_target?(project, dependency, model_b)
    end.group_by(&:product_name)
    templates = shipping.package_product_dependencies.map do |dependency|
      [dependency.product_name, dependency.package, dependency]
    end
    ordered = templates.map do |product_name, package, _shipping_dependency|
      candidates = existing_by_name.fetch(product_name, [])
      dependency = candidates.shift || project.new(
        Xcodeproj::Project::Object::XCSwiftPackageProductDependency
      )
      dependency.product_name = product_name
      dependency.package = package
      dependency
    end

    ordered_ids = ordered.map(&:uuid)
    stale = original.reject { |dependency| ordered_ids.include?(dependency.uuid) }
    stale.each do |dependency|
      model_b.build_phases.each do |phase|
        next unless phase.respond_to?(:files)
        phase.files.dup.each do |build_file|
          next unless build_file.product_ref&.uuid == dependency.uuid

          remove_build_file_from_phase(project, phase, build_file)
        end
      end
    end

    model_b.package_product_dependencies.clear
    ordered.each { |dependency| model_b.package_product_dependencies << dependency }
    stale.each do |dependency|
      dependency.remove_from_project unless package_dependency_referenced?(project, dependency)
    end
    package_map = {}
    templates.zip(ordered).each do |(_name, _package, shipping_dependency), model_dependency|
      package_map[shipping_dependency] = model_dependency if shipping_dependency
    end
    package_map
  end

  def build_file_key(build_file)
    if build_file.product_ref
      [:product, build_file.product_ref.uuid]
    elsif build_file.file_ref
      [:file, build_file.file_ref.uuid]
    else
      [:empty, build_file.uuid]
    end
  end

  def build_file_metadata(build_file)
    {
      settings: build_file.settings,
      platform_filter: build_file.platform_filter,
      platform_filters: build_file.platform_filters
    }
  end

  def apply_build_file_metadata(build_file, metadata)
    build_file.settings = duplicate_value(metadata.fetch(:settings))
    build_file.platform_filter = metadata.fetch(:platform_filter)
    build_file.platform_filters = duplicate_value(metadata.fetch(:platform_filters))
  end

  def reconcile_phase_files(project, source, destination, package_map,
                            extra_file_refs: [], extra_file_metadata: {}, extra_products: [],
                            excluded_file_paths: [])
    desired = source.files.compact.reject do |source_build_file|
      source_build_file.file_ref &&
        excluded_file_paths.include?(source_path(project, source_build_file.file_ref))
    end.map do |source_build_file|
      if source_build_file.product_ref
        [source_build_file, :product, package_map.fetch(source_build_file.product_ref),
         build_file_metadata(source_build_file)]
      else
        [source_build_file, :file, source_build_file.file_ref, build_file_metadata(source_build_file)]
      end
    end
    desired.concat(extra_file_refs.map do |reference|
      [nil, :file, reference, extra_file_metadata.fetch(reference.uuid)]
    end)
    desired.concat(extra_products.map do |dependency|
      [nil, :product, dependency, EMPTY_SOURCE_BUILD_FILE_METADATA]
    end)

    existing = destination.files.compact.select do |build_file|
      build_file_owners(project, build_file).map(&:uuid) == [destination.uuid]
    end.group_by { |build_file| build_file_key(build_file) }
    ordered = desired.map do |_source_build_file, kind, reference, metadata|
      key = [kind, reference.uuid]
      build_file = existing.fetch(key, []).shift || project.new(
        Xcodeproj::Project::Object::PBXBuildFile
      )
      if kind == :product
        build_file.product_ref = reference
        build_file.file_ref = nil
      else
        build_file.file_ref = reference
        build_file.product_ref = nil
      end
      apply_build_file_metadata(build_file, metadata)
      build_file
    end

    ordered_ids = ordered.map(&:uuid)
    destination.files.to_a.compact.reject do |build_file|
      ordered_ids.include?(build_file.uuid)
    end.each do |build_file|
      remove_build_file_from_phase(project, destination, build_file)
    end
    destination.files.clear
    ordered.each { |build_file| destination.files << build_file }
  end

  def reconcile_regular_phases(project, shipping, model_b, package_map, model_b_sources)
    source_phases = shipping.build_phases.reject do |phase|
      extension_embed_phase?(phase) || python_embed_phase?(phase) || python_install_phase?(phase)
    end
    available = model_b.build_phases.reject { |phase| extension_embed_phase?(phase) }
                             .select { |phase| phase_owners(project, phase).map(&:uuid) == [model_b.uuid] }
                             .group_by { |phase| phase_key(phase) }

    ordered = source_phases.map do |source|
      destination = available.fetch(phase_key(source), []).shift || new_phase(project, source)
      copy_common_phase_attributes(source, destination)
      extra_file_refs = source.is_a?(Xcodeproj::Project::Object::PBXSourcesBuildPhase) ? model_b_sources : []
      extra_file_metadata = extra_file_refs.to_h do |reference|
        [reference.uuid, MODEL_B_ONLY_SOURCE_METADATA.fetch(source_path(project, reference))]
      end
      excluded_file_paths = if source.is_a?(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
                              PYTHON_ONLY_SOURCE_PATHS
                            elsif source.is_a?(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
                              [PYTHON_FRAMEWORK_PATH]
                            elsif source.is_a?(Xcodeproj::Project::Object::PBXResourcesBuildPhase)
                              [PYTHON_RESOURCE_PATH]
                            else
                              []
                            end
      reconcile_phase_files(
        project, source, destination, package_map,
        extra_file_refs: extra_file_refs,
        extra_file_metadata: extra_file_metadata,
        excluded_file_paths: excluded_file_paths
      )
      destination
    end

    ordered_ids = ordered.map(&:uuid)
    stale = model_b.build_phases.reject { |phase| extension_embed_phase?(phase) }
                   .reject { |phase| ordered_ids.include?(phase.uuid) }
    stale.each { |phase| remove_phase_for_target(project, model_b, phase) }
    ordered
  end

  def reconcile_extension_dependency(model_b, extension)
    matching = model_b.dependencies.select { |dependency| dependency.target == extension }
    retained = matching.first
    model_b.dependencies.dup.each do |dependency|
      remove_dependency(dependency) unless dependency == retained
    end
    model_b.add_dependency(extension) unless retained
  end

  def reconcile_extension_embed(project, model_b, extension)
    all_candidates = model_b.build_phases.select { |phase| extension_embed_phase?(phase) }
    candidates = all_candidates.select do |candidate|
      phase_owners(project, candidate).map(&:uuid) == [model_b.uuid]
    end
    phase = candidates.shift || project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
    all_candidates.reject { |candidate| candidate.uuid == phase.uuid }.each do |duplicate|
      remove_phase_for_target(project, model_b, duplicate)
    end

    phase.name = 'Embed App Extensions'
    phase.symbol_dst_subfolder_spec = :plug_ins
    phase.dst_path = ''
    phase.build_action_mask = '2147483647'
    phase.run_only_for_deployment_postprocessing = '0'

    matching = phase.files.select do |build_file|
      build_file.file_ref == extension.product_reference &&
        build_file_owners(project, build_file).map(&:uuid) == [phase.uuid]
    end
    build_file = matching.shift || project.new(Xcodeproj::Project::Object::PBXBuildFile)
    phase.files.to_a.reject { |candidate| candidate.uuid == build_file.uuid }.each do |stale|
      remove_build_file_from_phase(project, phase, stale)
    end
    build_file.file_ref = extension.product_reference
    build_file.product_ref = nil
    build_file.settings = {
      'ATTRIBUTES' => %w[RemoveHeadersOnCopy CodeSignOnCopy]
    }
    phase.files.clear
    phase.files << build_file
    phase
  end

  def reconcile_configurations(project, shipping, model_b)
    existing = model_b.build_configurations.group_by(&:name)
    ordered = shipping.build_configurations.map do |source|
      configuration = existing.fetch(source.name, []).shift || project.new(
        Xcodeproj::Project::Object::XCBuildConfiguration
      )
      destination_tokens = compilation_tokens(configuration).reject do |token|
        SHIPPING_FORBIDDEN_FLAGS.include?(token)
      end
      configuration.name = source.name
      configuration.base_configuration_reference = source.base_configuration_reference
      configuration.build_settings = duplicate_value(source.build_settings)
      configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = MODEL_B_ENTITLEMENTS
      configuration.build_settings.delete('SWIFT_OBJC_BRIDGING_HEADER')
      required = destination_tokens
      required.concat(SHARED_APP_FLAGS)
      required.concat(MODEL_B_FLAGS)
      set_compilation_tokens(configuration, required, removed: SHIPPING_FORBIDDEN_FLAGS)
      configuration
    end

    (model_b.build_configurations.to_a - ordered).each(&:remove_from_project)
    model_b.build_configuration_list.build_configurations.clear
    ordered.each { |configuration| model_b.build_configuration_list.build_configurations << configuration }
    model_b.build_configuration_list.default_configuration_name =
      shipping.build_configuration_list.default_configuration_name
    model_b.build_configuration_list.default_configuration_is_visible =
      shipping.build_configuration_list.default_configuration_is_visible

    shipping.build_configurations.each do |configuration|
      configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = SHIPPING_ENTITLEMENTS
      configuration.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = PYTHON_BRIDGING_HEADER
      set_compilation_tokens(
        configuration,
        ['COLUMBA_RUNTIME_PYTHON'] + SHARED_APP_FLAGS,
        removed: SHIPPING_FORBIDDEN_FLAGS + SHARED_APP_FLAGS
      )
    end
  end

  def reconcile_shipping_test_configurations(project, shipping)
    shipping_tests = project.targets.find { |target| target.name == SHIPPING_TEST_TARGET_NAME } or
      raise "Missing #{SHIPPING_TEST_TARGET_NAME} target"
    unless shipping_tests.dependencies.any? { |dependency| dependency.target == shipping }
      raise "#{SHIPPING_TEST_TARGET_NAME} does not depend on #{SHIPPING_TARGET_NAME}"
    end

    shipping_by_name = shipping.build_configurations.to_h do |configuration|
      [configuration.name, configuration]
    end
    shipping_tests.build_configurations.each do |test_configuration|
      shipping_configuration = shipping_by_name.fetch(test_configuration.name)
      shipping_flags = compilation_tokens(shipping_configuration) & (CANONICAL_FLAGS + SHARED_APP_FLAGS)
      set_compilation_tokens(
        test_configuration,
        shipping_flags,
        removed: SHIPPING_FORBIDDEN_FLAGS + SHARED_APP_FLAGS
      )
    end
  end

  def reconcile_target_identity(project, shipping, model_b)
    model_b.name = MODEL_B_TARGET_NAME
    model_b.product_name = MODEL_B_TARGET_NAME
    model_b.product_type = 'com.apple.product-type.application'
    model_b.product_reference.path = "#{MODEL_B_TARGET_NAME}.app"
    model_b.product_reference.explicit_file_type = shipping.product_reference.explicit_file_type
    model_b.product_reference.source_tree = shipping.product_reference.source_tree

    attributes = project.root_object.attributes['TargetAttributes'] ||= {}
    attributes[model_b.uuid] = duplicate_value(attributes.fetch(shipping.uuid, {}))
  end

  def remove_duplicate_target(project, duplicate)
    project.targets.each do |target|
      target.dependencies.dup.each do |dependency|
        proxy_target_id = dependency.target_proxy&.remote_global_id_string
        target_id = dependency.target&.uuid
        if target_id == duplicate.uuid || proxy_target_id == duplicate.uuid
          detach_dependency(project, target, dependency)
        end
      end
    end
    duplicate.dependencies.dup.each do |dependency|
      detach_dependency(project, duplicate, dependency)
    end

    duplicate.build_phases.dup.each do |phase|
      remove_phase_for_target(project, duplicate, phase)
    end
    duplicate.build_configurations.dup.each(&:remove_from_project)
    duplicate.build_configuration_list.remove_from_project
    duplicate.package_product_dependencies.dup.each do |dependency|
      duplicate.package_product_dependencies.delete_if do |candidate|
        candidate.uuid == dependency.uuid
      end
      dependency.remove_from_project unless package_dependency_referenced?(project, dependency)
    end

    product = duplicate.product_reference
    product_id = product&.uuid
    # PBX objects compare by semantic content in xcodeproj. Give the stale
    # product a unique identity before removal so referrer cleanup cannot also
    # match and detach the retained same-named product reference.
    product.path = "__stale_#{product_id}.app" if product
    attributes = project.root_object.attributes['TargetAttributes'] ||= {}
    attributes.delete(duplicate.uuid)
    duplicate.remove_from_project

    return unless product_id && project.objects_by_uuid.key?(product_id)

    project.objects.select do |object|
      object.is_a?(Xcodeproj::Project::Object::PBXBuildFile) &&
        object.file_ref&.uuid == product_id
    end.each { |build_file| remove_build_file(build_file) }
    project.objects_by_uuid.fetch(product_id).remove_from_project
  end

  def clean_target_metadata(project, model_b)
    products = project.products_group.children.select do |reference|
      reference.path == "#{MODEL_B_TARGET_NAME}.app"
    end
    products.reject { |product| product.uuid == model_b.product_reference.uuid }.each do |product|
      product_id = product.uuid
      product.path = "__stale_#{product_id}.app"
      project.objects.select do |object|
        object.is_a?(Xcodeproj::Project::Object::PBXBuildFile) &&
          object.file_ref&.uuid == product_id
      end.each { |build_file| remove_build_file(build_file) }
      product.remove_from_project
    end

    attributes = project.root_object.attributes['TargetAttributes'] ||= {}
    live_target_ids = project.targets.map(&:uuid)
    attributes.delete_if { |uuid, _value| !live_target_ids.include?(uuid) }
  end

  def create_or_find_model_b(project, shipping)
    existing = project.targets.select { |target| target.name == MODEL_B_TARGET_NAME }
    model_b = existing.shift
    existing.each { |duplicate| remove_duplicate_target(project, duplicate) }
    model_b ||= project.new_target(:application, MODEL_B_TARGET_NAME, :ios, nil)
    reconcile_target_identity(project, shipping, model_b)
    clean_target_metadata(project, model_b)
    model_b
  end

  def reconcile_model_b_tests(project, shipping_tests, model_b)
    existing = project.targets.select { |target| target.name == MODEL_B_TEST_TARGET_NAME }
    model_b_tests = existing.shift
    existing.each { |duplicate| remove_duplicate_target(project, duplicate) }
    model_b_tests ||= project.new_target(:unit_test_bundle, MODEL_B_TEST_TARGET_NAME, :ios, nil)

    # Localize every mutable edge before applying authoritative XCTest state.
    # In particular, a malformed target may point directly at a shipping
    # product, phase, build file, configuration, dependency, or proxy.
    product = localize_test_product(project, model_b_tests, shipping_tests.product_reference)
    localize_test_phases(project, model_b_tests)
    localize_test_configurations(project, model_b_tests)

    model_b_tests.name = MODEL_B_TEST_TARGET_NAME
    model_b_tests.product_name = MODEL_B_TEST_TARGET_NAME
    model_b_tests.product_type = 'com.apple.product-type.bundle.unit-test'
    product.path = "#{MODEL_B_TEST_TARGET_NAME}.xctest"
    product.name = nil
    product.explicit_file_type = 'wrapper.cfbundle'
    product.source_tree = 'BUILT_PRODUCTS_DIR'
    clean_test_products(project, product)

    # The test target owns exactly one Sources, Frameworks, and Resources phase.
    phase_classes = [
      Xcodeproj::Project::Object::PBXSourcesBuildPhase,
      Xcodeproj::Project::Object::PBXFrameworksBuildPhase,
      Xcodeproj::Project::Object::PBXResourcesBuildPhase
    ]
    phases = phase_classes.map do |klass|
      candidates = model_b_tests.build_phases.select { |phase| phase.is_a?(klass) }
      retained = candidates.shift || project.new(klass)
      candidates.each { |phase| remove_phase_for_target(project, model_b_tests, phase) }
      retained
    end
    model_b_tests.build_phases.to_a.each do |phase|
      remove_phase_for_target(project, model_b_tests, phase) unless phases.any? { |kept| kept.uuid == phase.uuid }
    end
    model_b_tests.build_phases.clear
    phases.each { |phase| model_b_tests.build_phases << phase }
    source_phase, framework_phase, resources_phase = phases

    references = project.files.each_with_object({}) do |reference, by_path|
      path = source_path(project, reference)
      by_path[path] = reference if MODEL_B_ONLY_TEST_SOURCE_PATHS.include?(path)
    end
    missing = MODEL_B_ONLY_TEST_SOURCE_PATHS - references.keys
    raise "Missing Model B test source references: #{missing.join(', ')}" unless missing.empty?
    retained_files = MODEL_B_ONLY_TEST_SOURCE_PATHS.map do |path|
      matching = source_phase.files.select do |build_file|
        build_file.file_ref && source_path(project, build_file.file_ref) == path &&
          build_file_owners(project, build_file).map(&:uuid) == [source_phase.uuid]
      end
      build_file = matching.shift || project.new(Xcodeproj::Project::Object::PBXBuildFile)
      build_file.file_ref = references.fetch(path)
      build_file.product_ref = nil
      apply_build_file_metadata(build_file, EMPTY_SOURCE_BUILD_FILE_METADATA)
      build_file
    end
    retained_ids = retained_files.map(&:uuid)
    source_phase.files.compact.dup.each do |build_file|
      remove_build_file_from_phase(project, source_phase, build_file) unless retained_ids.include?(build_file.uuid)
    end
    source_phase.files.clear
    retained_files.each { |build_file| source_phase.files << build_file }

    # Keep the SDK Foundation.framework link target-local; all package links are
    # rebuilt below, and test resources are intentionally empty.
    foundation_reference = project.files.find do |reference|
      reference.display_name == 'Foundation.framework'
    end or raise 'project lacks Foundation.framework reference'
    foundation_file = local_build_file_for_reference(project, framework_phase, foundation_reference)
    apply_build_file_metadata(foundation_file, EMPTY_SOURCE_BUILD_FILE_METADATA)
    framework_phase.files.compact.dup.each do |build_file|
      next if build_file.uuid == foundation_file.uuid || build_file.product_ref

      remove_build_file_from_phase(project, framework_phase, build_file)
    end
    resources_phase.files.compact.dup.each do |build_file|
      remove_build_file_from_phase(project, resources_phase, build_file)
    end

    original_packages = model_b_tests.package_product_dependencies.to_a
    model_b_tests.build_phases.each do |phase|
      phase.files.compact.dup.each do |build_file|
        next unless build_file.product_ref
        next if build_file.product_ref.product_name == RETICULUM_PRODUCT_NAME

        remove_build_file_from_phase(project, phase, build_file)
      end
    end
    model_b_tests.package_product_dependencies.clear
    original_packages.select { |dependency| dependency.product_name == RETICULUM_PRODUCT_NAME }.each do |dependency|
      model_b_tests.package_product_dependencies << dependency
    end
    original_packages.reject { |dependency| dependency.product_name == RETICULUM_PRODUCT_NAME }.each do |dependency|
      dependency.remove_from_project unless package_dependency_referenced?(project, dependency)
    end
    reticulum_package = model_b.package_product_dependencies.find do |dependency|
      dependency.product_name == RETICULUM_PRODUCT_NAME
    end&.package
    raise 'Model B host lacks ReticulumSwift package reference' unless reticulum_package
    reconcile_required_package_product(project, model_b_tests, RETICULUM_PRODUCT_NAME, reticulum_package)

    retained_dependency = model_b_tests.dependencies.find do |dependency|
      dependency.target&.uuid == model_b.uuid &&
        dependency_owners(project, dependency).map(&:uuid) == [model_b_tests.uuid] &&
        proxy_users(project, dependency.target_proxy).map(&:uuid) == [dependency.uuid]
    end
    model_b_tests.dependencies.to_a.each do |dependency|
      detach_dependency(project, model_b_tests, dependency) unless dependency.uuid == retained_dependency&.uuid
    end
    model_b_tests.add_dependency(model_b) unless retained_dependency

    attributes = project.root_object.attributes['TargetAttributes'] ||= {}
    attributes[model_b_tests.uuid] = duplicate_value(attributes.fetch(shipping_tests.uuid, {}))
    attributes[model_b_tests.uuid]['TestTargetID'] = model_b.uuid

    shipping_configs = {}
    shipping_tests.build_configurations.each { |configuration| shipping_configs[configuration.name] = configuration }
    existing_configs = model_b_tests.build_configurations.group_by(&:name)
    ordered_configs = model_b.build_configurations.map do |host_configuration|
      configuration = existing_configs.fetch(host_configuration.name, []).shift || project.new(
        Xcodeproj::Project::Object::XCBuildConfiguration
      )
      template = shipping_configs.fetch(host_configuration.name)
      configuration.name = host_configuration.name
      configuration.base_configuration_reference = template.base_configuration_reference
      configuration.build_settings = duplicate_value(template.build_settings)
      configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'network.columba.ColumbaModelB.tests'
      configuration.build_settings['TEST_HOST'] =
        '$(BUILT_PRODUCTS_DIR)/ColumbaModelBApp.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/ColumbaModelBApp'
      configuration.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
      configuration.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
        host_configuration.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']
      configuration
    end
    stale_configs = model_b_tests.build_configurations.to_a.reject do |configuration|
      ordered_configs.any? { |retained| retained.uuid == configuration.uuid }
    end
    model_b_tests.build_configuration_list.build_configurations.clear
    ordered_configs.each { |configuration| model_b_tests.build_configuration_list.build_configurations << configuration }
    stale_configs.each do |configuration|
      configuration.remove_from_project if configuration_owners(project, configuration).empty?
    end
    model_b_tests.build_configuration_list.default_configuration_name =
      model_b.build_configuration_list.default_configuration_name
    model_b_tests.build_configuration_list.default_configuration_is_visible =
      model_b.build_configuration_list.default_configuration_is_visible
    attributes.delete_if { |uuid, _value| !project.targets.any? { |target| target.uuid == uuid } }
    clean_orphan_graph_nodes(project)
    model_b_tests
  end

  def scheme_xml(app, tests, extension = nil)
    buildables = [app, extension].compact.map do |target|
      <<~XML
               <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
                  <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{target.uuid}" BuildableName = "#{target.product_reference.path}" BlueprintName = "#{target.name}" ReferencedContainer = "container:Columba.xcodeproj">
                  </BuildableReference>
               </BuildActionEntry>
      XML
    end.join
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Scheme LastUpgradeVersion = "1500" version = "1.7">
         <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
            <BuildActionEntries>
      #{buildables.rstrip}
            </BuildActionEntries>
         </BuildAction>
         <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES" shouldAutocreateTestPlan = "YES">
            <Testables>
               <TestableReference skipped = "NO">
                  <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{tests.uuid}" BuildableName = "#{tests.product_reference.path}" BlueprintName = "#{tests.name}" ReferencedContainer = "container:Columba.xcodeproj">
                  </BuildableReference>
               </TestableReference>
            </Testables>
         </TestAction>
         <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
            <BuildableProductRunnable runnableDebuggingMode = "0">
               <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{app.uuid}" BuildableName = "#{app.product_reference.path}" BlueprintName = "#{app.name}" ReferencedContainer = "container:Columba.xcodeproj">
               </BuildableReference>
            </BuildableProductRunnable>
         </LaunchAction>
         <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
            <BuildableProductRunnable runnableDebuggingMode = "0">
               <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{app.uuid}" BuildableName = "#{app.product_reference.path}" BlueprintName = "#{app.name}" ReferencedContainer = "container:Columba.xcodeproj">
               </BuildableReference>
            </BuildableProductRunnable>
         </ProfileAction>
         <AnalyzeAction buildConfiguration = "Debug">
         </AnalyzeAction>
         <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
         </ArchiveAction>
      </Scheme>
    XML
  end

  def reconcile_shared_schemes(project, shipping, shipping_tests, model_b, model_b_tests, extension)
    schemes_dir = File.join(project.path.to_s, 'xcshareddata', 'xcschemes')
    Dir.mkdir(File.join(project.path.to_s, 'xcshareddata')) unless Dir.exist?(File.join(project.path.to_s, 'xcshareddata'))
    Dir.mkdir(schemes_dir) unless Dir.exist?(schemes_dir)
    Dir.glob(File.join(schemes_dir, '*.xcscheme')).each { |path| File.delete(path) }
    File.write(File.join(schemes_dir, 'Columba.xcscheme'), scheme_xml(shipping, shipping_tests))
    File.write(
      File.join(schemes_dir, 'Columba-ModelB.xcscheme'),
      scheme_xml(model_b, model_b_tests, extension)
    )
  end

  def assert_graph!(project)
    shipping = project.targets.select { |target| target.name == SHIPPING_TARGET_NAME }
    model_b = project.targets.select { |target| target.name == MODEL_B_TARGET_NAME }
    extension = project.targets.select { |target| target.name == EXTENSION_TARGET_NAME }
    model_b_tests = project.targets.select { |target| target.name == MODEL_B_TEST_TARGET_NAME }
    raise 'target names are not unique' unless [shipping, model_b, extension, model_b_tests].all? { |targets| targets.one? }

    shipping = shipping.first
    model_b = model_b.first
    extension = extension.first
    model_b_tests = model_b_tests.first
    raise 'shipping target still depends on extension' if shipping.dependencies.any? { |dep| dep.target == extension }
    raise 'shipping target retained an extension embed phase' if shipping.build_phases.any? do |phase|
      extension_embed_phase?(phase)
    end
    raise 'shipping target still embeds extension' if shipping.build_phases.any? do |phase|
      phase.respond_to?(:files) && phase.files.any? { |file| file.file_ref == extension.product_reference }
    end
    raise 'Model B extension dependency is not unique' unless model_b.dependencies.count { |dep| dep.target == extension } == 1
    raise 'Model B has stale target dependencies' unless model_b.dependencies.one?
    model_b_test_sources = model_b_tests.source_build_phase.files.map do |file|
      source_path(project, file.file_ref)
    end
    raise 'Model B test source membership is incorrect' unless
      model_b_test_sources == MODEL_B_ONLY_TEST_SOURCE_PATHS
    raise 'Model B XCTest host dependency is incorrect' unless
      model_b_tests.dependencies.one? && model_b_tests.dependencies.first.target == model_b
    test_dependency = model_b_tests.dependencies.first
    unless dependency_owners(project, test_dependency).map(&:uuid) == [model_b_tests.uuid] &&
           proxy_users(project, test_dependency.target_proxy).map(&:uuid) == [test_dependency.uuid]
      raise 'Model B XCTest dependency/proxy is not target-local'
    end
    expected_test_phase_classes = [
      Xcodeproj::Project::Object::PBXSourcesBuildPhase,
      Xcodeproj::Project::Object::PBXFrameworksBuildPhase,
      Xcodeproj::Project::Object::PBXResourcesBuildPhase
    ]
    unless model_b_tests.build_phases.map(&:class) == expected_test_phase_classes &&
           model_b_tests.build_phases.all? { |phase| phase_owners(project, phase).map(&:uuid) == [model_b_tests.uuid] }
      raise 'Model B XCTest phases are not exact and target-local'
    end
    configurations_local = model_b_tests.build_configurations.all? do |configuration|
      configuration_owners(project, configuration).map(&:uuid) ==
        [model_b_tests.build_configuration_list.uuid]
    end
    unless configuration_list_owners(project, model_b_tests.build_configuration_list).map(&:uuid) ==
             [model_b_tests.uuid] && configurations_local
      raise 'Model B XCTest configurations are not target-local'
    end
    test_product = model_b_tests.product_reference
    test_product_ids = project.products_group.children.select do |reference|
      reference.path == "#{MODEL_B_TEST_TARGET_NAME}.xctest"
    end.map(&:uuid)
    unless test_product_ids == [test_product.uuid] &&
           product_owners(project, test_product).map(&:uuid) == [model_b_tests.uuid]
      raise 'Model B XCTest product reference is not unique and target-local'
    end
    orphan_test_products = project.products_group.children.select do |reference|
      reference.path.to_s.end_with?('.xctest') && product_owners(project, reference).empty?
    end
    unless orphan_test_products.empty?
      raise "orphan XCTest products: #{orphan_test_products.map(&:uuid).join(', ')}"
    end
    target_attributes = project.root_object.attributes.fetch('TargetAttributes', {})
    unless target_attributes.fetch(model_b_tests.uuid, {})['TestTargetID'] == model_b.uuid
      raise 'Model B XCTest TargetAttributes.TestTargetID is incorrect'
    end
    test_products = model_b_tests.package_product_dependencies
    unless test_products.map(&:product_name) == [RETICULUM_PRODUCT_NAME]
      raise 'Model B XCTest package membership is incorrect'
    end
    test_reticulum = test_products.first
    host_reticulum = model_b.package_product_dependencies.find do |dependency|
      dependency.product_name == RETICULUM_PRODUCT_NAME
    end
    if test_reticulum.uuid == host_reticulum&.uuid
      raise 'Model B app and XCTest targets share a ReticulumSwift package dependency object'
    end
    unless test_reticulum.package&.uuid == host_reticulum&.package&.uuid
      raise 'Model B XCTest ReticulumSwift dependency uses the wrong root package reference'
    end
    test_reticulum_files = model_b_tests.build_phases.flat_map(&:files).select do |file|
      file.product_ref&.product_name == RETICULUM_PRODUCT_NAME
    end
    unless test_reticulum_files.one? &&
           test_reticulum_files.first.product_ref&.uuid == test_reticulum.uuid &&
           build_file_owners(project, test_reticulum_files.first).map(&:uuid) ==
             [model_b_tests.frameworks_build_phase.uuid]
      raise 'Model B XCTest ReticulumSwift framework build file is not unique and target-local'
    end
    model_b_configs = {}
    model_b.build_configurations.each { |configuration| model_b_configs[configuration.name] = configuration }
    model_b_tests.build_configurations.each do |configuration|
      host = model_b_configs.fetch(configuration.name)
      raise "Model B TEST_HOST is incorrect in #{configuration.name}" unless
        configuration.build_settings.fetch('TEST_HOST', '').include?('ColumbaModelBApp.app')
      raise "Model B BUNDLE_LOADER is incorrect in #{configuration.name}" unless
        configuration.build_settings['BUNDLE_LOADER'] == '$(TEST_HOST)'
      raise "Model B host/test flavor mismatch in #{configuration.name}" unless
        configuration.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] ==
          host.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']
    end

    shipping_tests = project.targets.find { |target| target.name == SHIPPING_TEST_TARGET_NAME } or
      raise "Missing #{SHIPPING_TEST_TARGET_NAME} target"
    shipping_test_sources = shipping_tests.source_build_phase.files.map do |file|
      source_path(project, file.file_ref)
    end
    leaked_test_sources = shipping_test_sources & MODEL_B_ONLY_TEST_SOURCE_PATHS
    unless leaked_test_sources.empty?
      raise "shipping tests retained Model B-only sources: #{leaked_test_sources.join(', ')}"
    end
    raise 'shipping test target dependency changed' unless shipping_tests.dependencies.any? do |dependency|
      dependency.target == shipping
    end
    shipping_by_name = shipping.build_configurations.to_h do |configuration|
      [configuration.name, configuration]
    end
    shipping_tests.build_configurations.each do |test_configuration|
      shipping_configuration = shipping_by_name.fetch(test_configuration.name)
      test_flags = compilation_tokens(test_configuration) & CANONICAL_FLAGS
      shipping_flags = compilation_tokens(shipping_configuration) & CANONICAL_FLAGS
      raise "shipping host/test flavor mismatch in #{test_configuration.name}" unless test_flags == shipping_flags
      test_host = test_configuration.build_settings.fetch('TEST_HOST', '')
      raise "shipping TEST_HOST changed in #{test_configuration.name}" unless test_host.include?('ColumbaApp.app')
    end
    (shipping.build_configurations + shipping_tests.build_configurations).each do |configuration|
      missing = SHARED_APP_FLAGS - compilation_tokens(configuration)
      next if missing.empty?

      raise "shipping configuration lost shared features #{missing.join(', ')} in #{configuration.name}"
    end
    model_b.build_configurations.each do |configuration|
      missing = SHARED_APP_FLAGS - compilation_tokens(configuration)
      next if missing.empty?

      raise "Model B shared feature mapping lost #{missing.join(', ')} in #{configuration.name}"
    end
    ([project] + project.targets).each do |owner|
      names = owner.build_configuration_list.build_configurations.map(&:name)
      stale = names & LEGACY_SWIFT_CONFIGURATION_NAMES
      raise "#{owner.respond_to?(:name) ? owner.name : 'project'} retained #{stale.join(', ')}" unless stale.empty?
    end

    embed_phases = model_b.build_phases.select { |phase| extension_embed_phase?(phase) }
    raise 'Model B embed phase is not unique' unless embed_phases.one?
    embed_files = embed_phases.first.files.select { |file| file.file_ref == extension.product_reference }
    raise 'Model B extension embed is not unique' unless embed_files.one?
    attributes = Array(embed_files.first.settings&.fetch('ATTRIBUTES', nil))
    raise 'Model B extension embed lacks CodeSignOnCopy' unless attributes.include?('CodeSignOnCopy')

    shipping_sources = shipping.source_build_phase.files.map do |file|
      source_path(project, file.file_ref)
    end
    model_b_sources = model_b.source_build_phase.files.map do |file|
      source_path(project, file.file_ref)
    end
    leaked_sources = shipping_sources & MODEL_B_ONLY_SOURCE_PATHS
    raise "shipping retained Model B sources: #{leaked_sources.join(', ')}" unless leaked_sources.empty?
    missing_python_sources = PYTHON_ONLY_SOURCE_PATHS - shipping_sources
    unless missing_python_sources.empty?
      raise "shipping lost Python-only sources: #{missing_python_sources.join(', ')}"
    end
    leaked_python_sources = model_b_sources & PYTHON_ONLY_SOURCE_PATHS
    unless leaked_python_sources.empty?
      raise "Model B retained Python-only sources: #{leaked_python_sources.join(', ')}"
    end
    missing_sources = MODEL_B_ONLY_SOURCE_PATHS - model_b_sources
    raise "Model B lost isolated sources: #{missing_sources.join(', ')}" unless missing_sources.empty?
    expected_model_sources = (shipping_sources - PYTHON_ONLY_SOURCE_PATHS) + MODEL_B_ONLY_SOURCE_PATHS
    unless model_b_sources == expected_model_sources
      raise 'Model B source membership is not shared shipping sources plus the isolated source set'
    end
    PYTHON_ONLY_SOURCE_METADATA.each do |path, expected_metadata|
      build_file = shipping.source_build_phase.files.find do |candidate|
        source_path(project, candidate.file_ref) == path
      end
      actual_metadata = build_file_metadata(build_file)
      next if actual_metadata == expected_metadata

      raise "shipping Python source metadata mismatch for #{path}"
    end
    MODEL_B_ONLY_SOURCE_METADATA.each do |path, expected_metadata|
      build_file = model_b.source_build_phase.files.find do |candidate|
        source_path(project, candidate.file_ref) == path
      end
      actual_metadata = build_file_metadata(build_file)
      next if actual_metadata == expected_metadata

      raise "Model B source metadata mismatch for #{path}: " \
            "expected #{expected_metadata.inspect}, got #{actual_metadata.inspect}"
    end

    shipping_framework_paths = shipping.frameworks_build_phase.files.each_with_object([]) do |file, paths|
      paths << source_path(project, file.file_ref) if file.file_ref
    end
    model_framework_paths = model_b.frameworks_build_phase.files.each_with_object([]) do |file, paths|
      paths << source_path(project, file.file_ref) if file.file_ref
    end
    raise 'shipping Python framework linkage is not unique' unless
      shipping_framework_paths.count(PYTHON_FRAMEWORK_PATH) == 1
    raise 'Model B retained Python framework linkage' if
      model_framework_paths.include?(PYTHON_FRAMEWORK_PATH)

    shipping_resource_paths = shipping.resources_build_phase.files.map do |file|
      source_path(project, file.file_ref)
    end
    model_resource_paths = model_b.resources_build_phase.files.map do |file|
      source_path(project, file.file_ref)
    end
    raise 'shipping Python resource tree is not unique' unless
      shipping_resource_paths.count(PYTHON_RESOURCE_PATH) == 1
    raise 'Model B retained Python resource tree' if model_resource_paths.include?(PYTHON_RESOURCE_PATH)

    embed_phases = shipping.build_phases.select { |phase| python_embed_phase?(phase) }
    raise 'shipping Python embed phase is not unique' unless embed_phases.one?
    embed = embed_phases.first
    embed_paths = embed.files.map { |file| source_path(project, file.file_ref) }
    raise 'shipping Python embed membership is incorrect' unless embed_paths == [PYTHON_FRAMEWORK_PATH]
    expected_embed_settings = { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] }
    raise 'shipping Python embed metadata is incorrect' unless
      embed.files.first.settings == expected_embed_settings && embed.dst_path == '' &&
      embed.dst_subfolder_spec.to_s == '10' && embed.build_action_mask == '2147483647' &&
      embed.run_only_for_deployment_postprocessing == '0'

    shell_phases = shipping.build_phases.select { |phase| python_install_phase?(phase) }
    raise 'shipping Python install phase is not unique' unless shell_phases.one?
    shell = shell_phases.first
    shell_metadata_ok = shell.shell_path == '/bin/sh' && shell.shell_script == PYTHON_INSTALL_SCRIPT &&
      shell.input_paths == ['$(PROJECT_DIR)/Frameworks/Python.xcframework/build/utils.sh'] &&
      shell.output_paths == [] && shell.input_file_list_paths == [] &&
      shell.output_file_list_paths == [] && shell.always_out_of_date == '1' &&
      shell.show_env_vars_in_log == '0' && shell.dependency_file.nil? &&
      shell.build_action_mask == '2147483647' && shell.run_only_for_deployment_postprocessing == '0'
    raise 'shipping Python install phase metadata is incorrect' unless shell_metadata_ok
    expected_shipping_phase_names = [nil, nil, nil, PYTHON_EMBED_PHASE_NAME, PYTHON_SHELL_PHASE_NAME]
    shipping_phase_names = shipping.build_phases.map do |phase|
      phase.respond_to?(:name) ? phase.name : nil
    end
    unless shipping_phase_names == expected_shipping_phase_names
      raise 'shipping Python phase order is incorrect'
    end
    if model_b.build_phases.any? { |phase| python_embed_phase?(phase) || python_install_phase?(phase) }
      raise 'Model B retained a Python packaging phase'
    end
    model_b.build_configurations.each do |configuration|
      if configuration.build_settings.key?('SWIFT_OBJC_BRIDGING_HEADER')
        raise "Model B retained Python bridging header in #{configuration.name}"
      end
    end
    shipping.build_configurations.each do |configuration|
      unless configuration.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] == PYTHON_BRIDGING_HEADER
        raise "shipping lost Python bridging header in #{configuration.name}"
      end
    end

    shipping_products = shipping.package_product_dependencies.map(&:product_name)
    model_b_products = model_b.package_product_dependencies.map(&:product_name)
    unless shipping_products.count(RETICULUM_PRODUCT_NAME) == 1
      raise 'shipping ReticulumSwift package dependency is not unique'
    end
    unless model_b_products == shipping_products && model_b_products.count(RETICULUM_PRODUCT_NAME) == 1
      raise 'Model B package membership does not exactly mirror shipping'
    end
    shipping_reticulum = shipping.package_product_dependencies.find do |dependency|
      dependency.product_name == RETICULUM_PRODUCT_NAME
    end
    model_b_reticulum = model_b.package_product_dependencies.find do |dependency|
      dependency.product_name == RETICULUM_PRODUCT_NAME
    end
    if shipping_reticulum.uuid == model_b_reticulum.uuid
      raise 'application targets share a ReticulumSwift package dependency object'
    end
    unless shipping_reticulum.package&.uuid == model_b_reticulum.package&.uuid
      raise 'application ReticulumSwift dependencies do not use the same root package reference'
    end
    [shipping, model_b].each do |target|
      files = target.build_phases.flat_map(&:files).select do |file|
        file.product_ref&.product_name == RETICULUM_PRODUCT_NAME
      end
      owned_dependency = target.package_product_dependencies.find do |dependency|
        dependency.product_name == RETICULUM_PRODUCT_NAME
      end
      unless files.one? && files.first.product_ref&.uuid == owned_dependency&.uuid
        raise "#{target.name} ReticulumSwift framework build file is not unique and target-local"
      end
    end

    phase_ownership = Hash.new { |hash, key| hash[key] = [] }
    project.targets.each do |target|
      target.build_phases.each { |phase| phase_ownership[phase.uuid] << target.name }
    end
    shared_phases = phase_ownership.select { |_uuid, owners| owners.size > 1 }
    raise "build phases have multiple target owners: #{shared_phases.inspect}" unless shared_phases.empty?

    build_file_ownership = Hash.new { |hash, key| hash[key] = [] }
    project.objects.each do |object|
      next unless object.respond_to?(:files)

      object.files.each { |build_file| build_file_ownership[build_file.uuid] << object.uuid }
    end
    shared_build_files = build_file_ownership.select { |_uuid, owners| owners.size > 1 }
    unless shared_build_files.empty?
      raise "PBXBuildFile objects have multiple phase owners: #{shared_build_files.inspect}"
    end
    orphan_build_files = project.objects.select do |object|
      object.is_a?(Xcodeproj::Project::Object::PBXBuildFile) &&
        build_file_ownership.fetch(object.uuid, []).empty?
    end
    unless orphan_build_files.empty?
      raise "orphan PBXBuildFile objects: #{orphan_build_files.map(&:uuid).join(', ')}"
    end

    package_ownership = Hash.new { |hash, key| hash[key] = [] }
    project.targets.each do |target|
      target.package_product_dependencies.each do |dependency|
        package_ownership[dependency.uuid] << target.uuid
      end
    end
    shared_packages = package_ownership.select { |_uuid, owners| owners.size > 1 }
    unless shared_packages.empty?
      raise "package product dependencies have multiple target owners: #{shared_packages.inspect}"
    end

    project.objects.each do |object|
      next unless object.is_a?(Xcodeproj::Project::Object::PBXBuildFile)

      has_file_ref = !object.file_ref.nil?
      has_product_ref = !object.product_ref.nil?
      unless has_file_ref ^ has_product_ref
        raise "PBXBuildFile #{object.uuid} must have exactly one file_ref or product_ref"
      end
      next unless has_product_ref

      build_file_owners(project, object).each do |phase|
        phase_owners(project, phase).each do |target|
          target_package_ids = target.package_product_dependencies.map(&:uuid)
          next if target_package_ids.include?(object.product_ref.uuid)

          raise "package build file #{object.uuid} references a product not owned by #{target.name}"
        end
      end
    end

    model_b_product_ids = project.products_group.children.each_with_object([]) do |reference, ids|
      ids << reference.uuid if reference.path == "#{MODEL_B_TARGET_NAME}.app"
    end
    unless model_b_product_ids == [model_b.product_reference.uuid]
      raise "Model B product reference is not unique: #{model_b_product_ids.join(', ')}"
    end

    target_ids = project.targets.map(&:uuid)
    attributes = project.root_object.attributes.fetch('TargetAttributes', {})
    stale_attributes = attributes.keys - target_ids
    unless stale_attributes.empty?
      raise "TargetAttributes contains nonexistent targets: #{stale_attributes.join(', ')}"
    end

    [shipping, model_b].each do |target|
      phase_ids = target.build_phases.map(&:uuid)
      raise "duplicate phases on #{target.name}" unless phase_ids.uniq == phase_ids
      target.build_phases.each do |phase|
        ids = phase.files.map(&:uuid)
        raise "duplicate build files in #{target.name}" unless ids.uniq == ids
      end
    end
  end
end

project = Xcodeproj::Project.open(PROJECT_PATH)
ModelBTargetIsolation.remove_legacy_swift_configurations(project)
shipping = project.targets.find { |target| target.name == SHIPPING_TARGET_NAME } or
  abort "Missing #{SHIPPING_TARGET_NAME} target"
# Xcodeproj can omit a newly restored PBXBuildFile when its owning phase was
# also created in the same serialization pass. Persist and reopen the purely
# structural localization first, then perform all canonical Python mutations on
# the reopened target-local phases.
if ModelBTargetIsolation.localize_shipping_canonical_phases(project, shipping)
  project.save
  project = Xcodeproj::Project.open(PROJECT_PATH)
  shipping = project.targets.find { |target| target.name == SHIPPING_TARGET_NAME } or
    abort "Missing #{SHIPPING_TARGET_NAME} target after canonical phase localization"
end
extension = project.targets.find { |target| target.name == EXTENSION_TARGET_NAME } or
  abort "Missing #{EXTENSION_TARGET_NAME} target"
existing_model_b = project.targets.find { |target| target.name == MODEL_B_TARGET_NAME }
reticulum_package = [existing_model_b, shipping].compact.lazy.map do |target|
  target.package_product_dependencies.find do |dependency|
    dependency.product_name == RETICULUM_PRODUCT_NAME
  end&.package
end.find(&:itself)
reticulum_package ||= ModelBTargetIsolation.root_reticulum_package_reference(project)
unless reticulum_package
  abort "Missing root #{RETICULUM_PRODUCT_NAME} package reference (#{RETICULUM_REPOSITORY_URL})"
end
model_b_sources = ModelBTargetIsolation.model_b_source_references(project)
ModelBTargetIsolation.ensure_python_source_references(project)
ModelBTargetIsolation.strip_shipping_model_b_membership(project, shipping)
ModelBTargetIsolation.strip_shipping_extension_graph(project, shipping, extension)
ModelBTargetIsolation.reconcile_shipping_python_sources(project, shipping)
ModelBTargetIsolation.reconcile_shipping_python_files(project, shipping)
ModelBTargetIsolation.reconcile_shipping_python_phases(project, shipping)
ModelBTargetIsolation.reconcile_required_package_product(
  project, shipping, RETICULUM_PRODUCT_NAME, reticulum_package
)
model_b = ModelBTargetIsolation.create_or_find_model_b(project, shipping)
package_map = ModelBTargetIsolation.reconcile_package_products(
  project, shipping, model_b
)
regular_phases = ModelBTargetIsolation.reconcile_regular_phases(
  project, shipping, model_b, package_map, model_b_sources
)
ModelBTargetIsolation.reconcile_extension_dependency(model_b, extension)
embed_phase = ModelBTargetIsolation.reconcile_extension_embed(project, model_b, extension)
model_b.build_phases.clear
(regular_phases + [embed_phase]).each { |phase| model_b.build_phases << phase }
ModelBTargetIsolation.reconcile_configurations(project, shipping, model_b)
ModelBTargetIsolation.reconcile_shipping_test_configurations(project, shipping)
shipping_tests = project.targets.find { |target| target.name == SHIPPING_TEST_TARGET_NAME } or
  abort "Missing #{SHIPPING_TEST_TARGET_NAME} target"
ModelBTargetIsolation.strip_shipping_model_b_test_membership(project, shipping_tests)
model_b_tests = ModelBTargetIsolation.reconcile_model_b_tests(
  project, shipping_tests, model_b
)
ModelBTargetIsolation.assert_graph!(project)
project.save
ModelBTargetIsolation.reconcile_shared_schemes(
  project, shipping, shipping_tests, model_b, model_b_tests, extension
)

# A successful reopen catches malformed references immediately on Linux too.
reopened = Xcodeproj::Project.open(PROJECT_PATH)
ModelBTargetIsolation.assert_graph!(reopened)
def commit_staged_project!
  atomic_exchange_paths!(PROJECT_PATH, SOURCE_PROJECT_PATH)
end

def atomic_exchange_paths!(left, right)
  handle = Fiddle::Handle::DEFAULT

  result = if RUBY_PLATFORM.include?('darwin')
             # renamex_np(..., RENAME_SWAP) atomically exchanges both directory
             # entries. The canonical project path therefore never disappears.
             renamex_np = Fiddle::Function.new(
               handle['renamex_np'],
               [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
               Fiddle::TYPE_INT
             )
             renamex_np.call(left, right, 0x00000002) # RENAME_SWAP
           elsif RUBY_PLATFORM.include?('linux')
             # Linux equivalent used by portable/static mutation tests.
             renameat2 = Fiddle::Function.new(
               handle['renameat2'],
               [
                 Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP,
                 Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP,
                 Fiddle::TYPE_INT
               ],
               Fiddle::TYPE_INT
             )
             renameat2.call(-100, left, -100, right, 0x00000002) # RENAME_EXCHANGE
           else
             abort "Atomic project publication is unsupported on #{RUBY_PLATFORM}"
           end

  return if result.zero?

  raise SystemCallError.new(
    "Atomic exchange failed for #{left} and #{right}",
    Fiddle.last_error
  )
end

commit_staged_project!
puts "Reconciled #{MODEL_B_TARGET_NAME}; #{SHIPPING_TARGET_NAME} no longer ships #{EXTENSION_TARGET_NAME}."
