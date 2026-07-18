#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
PROJECT_PATH = File.join(ROOT, 'Columba.xcodeproj')
SCRIPTS = {
  configure: File.join(ROOT, 'support/configure-xcodeproj.rb'),
  swift_config: File.join(ROOT, 'support/add-swift-backend-config.rb'),
  ne_dependencies: File.join(ROOT, 'support/add-ne-backend-deps.rb'),
  embed_ne: File.join(ROOT, 'support/embed-ne.rb'),
  reconciler: File.join(ROOT, 'support/isolate-modelb-targets.rb')
}.freeze

class Task11MaintenanceScriptIsolationTests < Minitest::Test
  def copy_project(directory)
    FileUtils.mkdir_p(directory)
    destination = File.join(directory, 'Columba.xcodeproj')
    FileUtils.cp_r(PROJECT_PATH, destination)
    destination
  end

  def run_script(key, project_path)
    Open3.capture3(
      { 'COLUMBA_PROJECT_PATH' => project_path },
      RbConfig.ruby,
      SCRIPTS.fetch(key)
    )
  end

  def project_tree_hash(project_path)
    digest = Digest::SHA256.new
    Dir.glob(File.join(project_path, '**/*'), File::FNM_DOTMATCH).sort.each do |path|
      next unless File.file?(path)

      digest << path.sub(project_path, '') << "\0" << File.binread(path)
    end
    digest.hexdigest
  end

  def target(project, name)
    matches = project.targets.select { |candidate| candidate.name == name }
    assert_equal 1, matches.length, "expected one #{name} target"
    matches.first
  end

  def extension_embed_phase?(phase)
    phase.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) &&
      (phase.name == 'Embed App Extensions' || phase.symbol_dst_subfolder_spec == :plug_ins)
  end

  def target_signature(target)
    {
      phases: target.build_phases.map do |phase|
        [phase.uuid, phase.isa, phase.respond_to?(:name) ? phase.name : nil,
         phase.files.map { |file| [file.uuid, file.file_ref&.uuid, file.product_ref&.uuid, file.settings] }]
      end,
      dependencies: target.dependencies.map do |dependency|
        [dependency.uuid, dependency.target&.uuid, dependency.target_proxy&.uuid]
      end,
      packages: target.package_product_dependencies.map do |dependency|
        [dependency.uuid, dependency.product_name, dependency.package&.uuid]
      end,
      configurations: target.build_configurations.map do |configuration|
        [configuration.uuid, configuration.name, Marshal.load(Marshal.dump(configuration.build_settings))]
      end
    }
  end

  def assert_extension_isolation(project)
    shipping = target(project, 'ColumbaApp')
    model_b = target(project, 'ColumbaModelBApp')
    extension = target(project, 'ColumbaNetworkExtension')

    refute shipping.dependencies.any? { |dependency| dependency.target&.uuid == extension.uuid }
    refute(shipping.build_phases.flat_map(&:files).any? do |file|
      file.file_ref&.uuid == extension.product_reference.uuid
    end)
    assert_equal 1, model_b.dependencies.count { |dependency| dependency.target&.uuid == extension.uuid }
    embeds = model_b.build_phases.select { |phase| extension_embed_phase?(phase) }
                    .flat_map(&:files)
                    .count { |file| file.file_ref&.uuid == extension.product_reference.uuid }
    assert_equal 1, embeds
  end

  def assert_no_legacy_swift_variants(project_path)
    project = Xcodeproj::Project.open(project_path)
    owners = [project] + project.targets
    owners.each do |owner|
      names = owner.build_configuration_list.build_configurations.map(&:name)
      refute_includes names, 'Debug-Swift'
      refute_includes names, 'Release-Swift'
    end
    refute File.exist?(File.join(project_path, 'xcshareddata/xcschemes/Columba-Swift.xcscheme'))
  end

  def assert_graph_ownership(project)
    phase_owners = Hash.new { |hash, key| hash[key] = [] }
    file_owners = Hash.new { |hash, key| hash[key] = [] }
    package_owners = Hash.new { |hash, key| hash[key] = [] }
    project.targets.each do |candidate|
      candidate.build_phases.each { |phase| phase_owners[phase.uuid] << candidate.uuid }
      candidate.package_product_dependencies.each do |dependency|
        package_owners[dependency.uuid] << candidate.uuid
      end
    end
    project.objects.grep(Xcodeproj::Project::Object::AbstractBuildPhase).each do |phase|
      phase.files.each { |file| file_owners[file.uuid] << phase.uuid }
    end
    assert phase_owners.values.all?(&:one?), 'orphan or multi-owner build phase'
    all_files = project.objects.grep(Xcodeproj::Project::Object::PBXBuildFile)
    assert all_files.all? { |file| file_owners[file.uuid].one? }, 'orphan or multi-owner build file'
    all_packages = project.objects.grep(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    assert all_packages.all? { |dependency| package_owners[dependency.uuid].one? },
           'orphan or multi-owner package product dependency'
  end

  def test_obsolete_bootstrap_and_swift_variant_scripts_fail_closed_without_mutation
    Dir.mktmpdir('task11-retired') do |directory|
      %i[configure swift_config].each do |key|
        temporary_project = copy_project(File.join(directory, key.to_s))
        before = project_tree_hash(temporary_project)
        output, error, status = run_script(key, temporary_project)
        refute status.success?, "#{key} must fail closed"
        assert_equal before, project_tree_hash(temporary_project), "#{key} mutated the project"
        guidance = output + error
        assert_includes guidance, 'ColumbaModelBApp'
        assert_includes guidance, 'Columba-ModelB'
        assert_includes guidance, 'support/isolate-modelb-targets.rb'
        assert_no_legacy_swift_variants(temporary_project)
      end
    end
  end

  def test_embed_ne_repairs_only_through_authoritative_model_b_reconciliation
    Dir.mktmpdir('task11-embed') do |directory|
      temporary_project = copy_project(directory)
      fixture = Xcodeproj::Project.open(temporary_project)
      shipping = target(fixture, 'ColumbaApp')
      model_b = target(fixture, 'ColumbaModelBApp')
      extension = target(fixture, 'ColumbaNetworkExtension')
      model_b.dependencies.dup.each do |dependency|
        dependency.remove_from_project if dependency.target&.uuid == extension.uuid
      end
      model_b.build_phases.select { |phase| extension_embed_phase?(phase) }.each(&:remove_from_project)
      fixture.save

      mutated = Xcodeproj::Project.open(temporary_project)
      shipping_before = target_signature(target(mutated, 'ColumbaApp'))
      _output, error, status = run_script(:embed_ne, temporary_project)
      assert status.success?, "embed-ne failed:\n#{error}"
      repaired = Xcodeproj::Project.open(temporary_project)
      assert_equal shipping_before, target_signature(target(repaired, 'ColumbaApp'))
      assert_extension_isolation(repaired)
      assert_no_legacy_swift_variants(temporary_project)
      assert_graph_ownership(repaired)

      first_hash = project_tree_hash(temporary_project)
      _output, error, status = run_script(:embed_ne, temporary_project)
      assert status.success?, "second embed-ne failed:\n#{error}"
      assert_equal first_hash, project_tree_hash(temporary_project)
    end
  end

  def test_add_ne_dependencies_is_extension_local_and_byte_idempotent
    Dir.mktmpdir('task11-add-ne') do |directory|
      temporary_project = copy_project(directory)
      before = Xcodeproj::Project.open(temporary_project)
      protected_names = %w[ColumbaApp ColumbaModelBApp ColumbaAppTests ColumbaModelBAppTests]
      protected = protected_names.to_h { |name| [name, target_signature(target(before, name))] }

      _output, error, status = run_script(:ne_dependencies, temporary_project)
      assert status.success?, "add-ne-backend-deps failed:\n#{error}"
      after = Xcodeproj::Project.open(temporary_project)
      protected.each do |name, signature|
        assert_equal signature, target_signature(target(after, name)), "#{name} was mutated"
      end
      extension = target(after, 'ColumbaNetworkExtension')
      assert_equal %w[LXMFSwift ReticulumSwift],
                   extension.package_product_dependencies.map(&:product_name).sort
      extension.package_product_dependencies.each do |dependency|
        owners = after.targets.select do |candidate|
          candidate.package_product_dependencies.any? { |item| item.uuid == dependency.uuid }
        end
        assert_equal [extension.uuid], owners.map(&:uuid)
        files = extension.frameworks_build_phase.files.select do |file|
          file.product_ref&.uuid == dependency.uuid
        end
        assert_equal 1, files.length
      end
      assert_extension_isolation(after)
      assert_graph_ownership(after)

      first_hash = project_tree_hash(temporary_project)
      _output, error, status = run_script(:ne_dependencies, temporary_project)
      assert status.success?, "second add-ne-backend-deps failed:\n#{error}"
      assert_equal first_hash, project_tree_hash(temporary_project)
    end
  end

  def test_add_ne_dependencies_repairs_missing_extension_local_objects_without_touching_apps
    Dir.mktmpdir('task11-add-ne-missing') do |directory|
      temporary_project = copy_project(directory)
      fixture = Xcodeproj::Project.open(temporary_project)
      extension = target(fixture, 'ColumbaNetworkExtension')
      stale_dependencies = extension.package_product_dependencies.select do |dependency|
        %w[ReticulumSwift LXMFSwift].include?(dependency.product_name)
      end
      extension.frameworks_build_phase.files.dup.each do |file|
        next unless stale_dependencies.any? { |dependency| file.product_ref&.uuid == dependency.uuid }

        file.remove_from_project
      end
      stale_dependencies.each do |dependency|
        extension.package_product_dependencies.delete(dependency)
        dependency.remove_from_project
      end
      fixture.save

      mutated = Xcodeproj::Project.open(temporary_project)
      protected_names = %w[ColumbaApp ColumbaModelBApp ColumbaAppTests ColumbaModelBAppTests]
      protected = protected_names.to_h { |name| [name, target_signature(target(mutated, name))] }
      _output, error, status = run_script(:ne_dependencies, temporary_project)
      assert status.success?, "missing-dependency repair failed:\n#{error}"
      repaired = Xcodeproj::Project.open(temporary_project)
      protected.each do |name, signature|
        assert_equal signature, target_signature(target(repaired, name)), "#{name} was mutated"
      end
      repaired_extension = target(repaired, 'ColumbaNetworkExtension')
      assert_equal %w[LXMFSwift ReticulumSwift],
                   repaired_extension.package_product_dependencies.map(&:product_name).sort
      assert_graph_ownership(repaired)

      first_hash = project_tree_hash(temporary_project)
      _output, error, status = run_script(:ne_dependencies, temporary_project)
      assert status.success?, "second missing-dependency repair failed:\n#{error}"
      assert_equal first_hash, project_tree_hash(temporary_project)
    end
  end
end
