#!/usr/bin/env ruby
# frozen_string_literal: true

# Authoritatively split the Model B host from the shipping Python host.
#
# This script intentionally starts ColumbaModelBApp with the same app sources,
# resources, frameworks, package products, copy phases, shell scripts, and build
# settings as ColumbaApp. Later isolation tasks subtract flavor-specific content.
# The Network Extension dependency and PlugIns embed are the only memberships
# moved here.

require 'xcodeproj'

PROJECT_PATH = File.expand_path(
  ENV.fetch('COLUMBA_PROJECT_PATH', File.expand_path('../Columba.xcodeproj', __dir__))
)
SHIPPING_TARGET_NAME = 'ColumbaApp'
SHIPPING_TEST_TARGET_NAME = 'ColumbaAppTests'
MODEL_B_TARGET_NAME = 'ColumbaModelBApp'
EXTENSION_TARGET_NAME = 'ColumbaNetworkExtension'
SHIPPING_ENTITLEMENTS = 'Sources/ColumbaApp/Resources/ColumbaApp.entitlements'
MODEL_B_ENTITLEMENTS = 'Sources/ColumbaApp/Resources/ColumbaModelBApp.entitlements'
CANONICAL_FLAGS = %w[
  COLUMBA_RUNTIME_PYTHON
  COLUMBA_RUNTIME_MODEL_B
  ENABLE_NETWORK_EXTENSION
  COLUMBA_BACKEND_SWIFT
].freeze
SHIPPING_FORBIDDEN_FLAGS = (CANONICAL_FLAGS + ['COLUMBA_ONBOARDING_ENABLED']).freeze
MODEL_B_FLAGS = %w[
  COLUMBA_RUNTIME_MODEL_B
  ENABLE_NETWORK_EXTENSION
  COLUMBA_BACKEND_SWIFT
].freeze

module ModelBTargetIsolation
  module_function

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
    dependency.remove_from_project
  end

  def strip_shipping_extension_graph(shipping, extension)
    shipping.dependencies.dup.each do |dependency|
      remove_dependency(dependency) if dependency.target == extension
    end

    shipping.build_phases.dup.each do |phase|
      next unless phase.respond_to?(:files)

      phase.files.dup.each do |build_file|
        remove_build_file(build_file) if build_file.file_ref == extension.product_reference
      end
      remove_phase(phase) if extension_embed_phase?(phase) && phase.files.empty?
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
    existing_by_name = model_b.package_product_dependencies.group_by(&:product_name)
    ordered = shipping.package_product_dependencies.map do |shipping_dependency|
      candidates = existing_by_name.fetch(shipping_dependency.product_name, [])
      dependency = candidates.shift || project.new(
        Xcodeproj::Project::Object::XCSwiftPackageProductDependency
      )
      dependency.product_name = shipping_dependency.product_name
      dependency.package = shipping_dependency.package
      dependency
    end

    stale = model_b.package_product_dependencies.to_a - ordered
    stale.each do |dependency|
      model_b.build_phases.each do |phase|
        next unless phase.respond_to?(:files)
        phase.files.dup.each do |build_file|
          remove_build_file(build_file) if build_file.product_ref == dependency
        end
      end
      dependency.remove_from_project
    end

    model_b.package_product_dependencies.clear
    ordered.each { |dependency| model_b.package_product_dependencies << dependency }
    shipping.package_product_dependencies.zip(ordered).to_h
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

  def reconcile_phase_files(project, source, destination, package_map)
    desired_refs = source.files.map do |source_build_file|
      if source_build_file.product_ref
        [:product, package_map.fetch(source_build_file.product_ref)]
      else
        [:file, source_build_file.file_ref]
      end
    end

    existing = destination.files.group_by { |build_file| build_file_key(build_file) }
    ordered = source.files.zip(desired_refs).map do |source_build_file, (kind, reference)|
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
      build_file.settings = duplicate_value(source_build_file.settings)
      build_file.platform_filter = source_build_file.platform_filter
      build_file.platform_filters = duplicate_value(source_build_file.platform_filters)
      build_file
    end

    (destination.files.to_a - ordered).each { |build_file| remove_build_file(build_file) }
    destination.files.clear
    ordered.each { |build_file| destination.files << build_file }
  end

  def reconcile_regular_phases(project, shipping, model_b, package_map)
    source_phases = shipping.build_phases.reject { |phase| extension_embed_phase?(phase) }
    available = model_b.build_phases.reject { |phase| extension_embed_phase?(phase) }
                             .group_by { |phase| phase_key(phase) }

    ordered = source_phases.map do |source|
      destination = available.fetch(phase_key(source), []).shift || new_phase(project, source)
      copy_common_phase_attributes(source, destination)
      reconcile_phase_files(project, source, destination, package_map)
      destination
    end

    stale = model_b.build_phases.reject { |phase| extension_embed_phase?(phase) } - ordered
    stale.each { |phase| remove_phase(phase) }
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
    candidates = model_b.build_phases.select { |phase| extension_embed_phase?(phase) }
    phase = candidates.shift || project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
    candidates.each { |duplicate| remove_phase(duplicate) }

    phase.name = 'Embed App Extensions'
    phase.symbol_dst_subfolder_spec = :plug_ins
    phase.dst_path = ''
    phase.build_action_mask = '2147483647'
    phase.run_only_for_deployment_postprocessing = '0'

    matching = phase.files.select { |build_file| build_file.file_ref == extension.product_reference }
    build_file = matching.shift || project.new(Xcodeproj::Project::Object::PBXBuildFile)
    matching.each { |duplicate| remove_build_file(duplicate) }
    (phase.files.to_a - [build_file]).each { |stale| remove_build_file(stale) }
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
      preserves_onboarding = (compilation_tokens(source) + compilation_tokens(configuration))
                             .include?('COLUMBA_ONBOARDING_ENABLED')
      configuration.name = source.name
      configuration.base_configuration_reference = source.base_configuration_reference
      configuration.build_settings = duplicate_value(source.build_settings)
      configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = MODEL_B_ENTITLEMENTS
      required = []
      required << 'COLUMBA_ONBOARDING_ENABLED' if preserves_onboarding
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
      set_compilation_tokens(
        configuration,
        ['COLUMBA_RUNTIME_PYTHON'],
        removed: SHIPPING_FORBIDDEN_FLAGS
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
      shipping_flags = compilation_tokens(shipping_configuration) & CANONICAL_FLAGS
      set_compilation_tokens(
        test_configuration,
        shipping_flags,
        removed: SHIPPING_FORBIDDEN_FLAGS
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

  def create_or_find_model_b(project, shipping)
    existing = project.targets.select { |target| target.name == MODEL_B_TARGET_NAME }
    model_b = existing.shift
    existing.each(&:remove_from_project)
    model_b ||= project.new_target(:application, MODEL_B_TARGET_NAME, :ios, nil)
    reconcile_target_identity(project, shipping, model_b)
    model_b
  end

  def assert_graph!(project)
    shipping = project.targets.select { |target| target.name == SHIPPING_TARGET_NAME }
    model_b = project.targets.select { |target| target.name == MODEL_B_TARGET_NAME }
    extension = project.targets.select { |target| target.name == EXTENSION_TARGET_NAME }
    raise 'target names are not unique' unless [shipping, model_b, extension].all? { |targets| targets.one? }

    shipping = shipping.first
    model_b = model_b.first
    extension = extension.first
    raise 'shipping target still depends on extension' if shipping.dependencies.any? { |dep| dep.target == extension }
    raise 'shipping target still embeds extension' if shipping.build_phases.any? do |phase|
      phase.respond_to?(:files) && phase.files.any? { |file| file.file_ref == extension.product_reference }
    end
    raise 'Model B extension dependency is not unique' unless model_b.dependencies.count { |dep| dep.target == extension } == 1
    raise 'Model B has stale target dependencies' unless model_b.dependencies.one?

    shipping_tests = project.targets.find { |target| target.name == SHIPPING_TEST_TARGET_NAME } or
      raise "Missing #{SHIPPING_TEST_TARGET_NAME} target"
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
      next unless compilation_tokens(configuration).include?('COLUMBA_ONBOARDING_ENABLED')

      raise "shipping configuration retained Model B onboarding in #{configuration.name}"
    end

    embed_phases = model_b.build_phases.select { |phase| extension_embed_phase?(phase) }
    raise 'Model B embed phase is not unique' unless embed_phases.one?
    embed_files = embed_phases.first.files.select { |file| file.file_ref == extension.product_reference }
    raise 'Model B extension embed is not unique' unless embed_files.one?
    attributes = Array(embed_files.first.settings&.fetch('ATTRIBUTES', nil))
    raise 'Model B extension embed lacks CodeSignOnCopy' unless attributes.include?('CodeSignOnCopy')

    reused = shipping.build_phases.flat_map(&:files).map(&:uuid) &
             model_b.build_phases.flat_map(&:files).map(&:uuid)
    raise "app targets reuse PBXBuildFile objects: #{reused.join(', ')}" unless reused.empty?

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
shipping = project.targets.find { |target| target.name == SHIPPING_TARGET_NAME } or
  abort "Missing #{SHIPPING_TARGET_NAME} target"
extension = project.targets.find { |target| target.name == EXTENSION_TARGET_NAME } or
  abort "Missing #{EXTENSION_TARGET_NAME} target"
model_b = ModelBTargetIsolation.create_or_find_model_b(project, shipping)
package_map = ModelBTargetIsolation.reconcile_package_products(project, shipping, model_b)
regular_phases = ModelBTargetIsolation.reconcile_regular_phases(project, shipping, model_b, package_map)
ModelBTargetIsolation.reconcile_extension_dependency(model_b, extension)
embed_phase = ModelBTargetIsolation.reconcile_extension_embed(project, model_b, extension)
model_b.build_phases.clear
(regular_phases + [embed_phase]).each { |phase| model_b.build_phases << phase }
ModelBTargetIsolation.reconcile_configurations(project, shipping, model_b)
ModelBTargetIsolation.reconcile_shipping_test_configurations(project, shipping)
ModelBTargetIsolation.strip_shipping_extension_graph(shipping, extension)
ModelBTargetIsolation.assert_graph!(project)
project.save

# A successful reopen catches malformed references immediately on Linux too.
reopened = Xcodeproj::Project.open(PROJECT_PATH)
ModelBTargetIsolation.assert_graph!(reopened)
puts "Reconciled #{MODEL_B_TARGET_NAME}; #{SHIPPING_TARGET_NAME} no longer ships #{EXTENSION_TARGET_NAME}."
