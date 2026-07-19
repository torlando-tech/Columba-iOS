#!/usr/bin/env ruby
# frozen_string_literal: true

# Maintain the native backend products on ColumbaNetworkExtension only.
# Package references are project-level and shared; package product dependencies
# and PBXBuildFiles are target/phase-local and are never shared with either app.
#
# Usage:
#   ruby support/add-ne-backend-deps.rb
#   COLUMBA_PROJECT_PATH=/tmp/Columba.xcodeproj ruby support/add-ne-backend-deps.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path(
  ENV.fetch('COLUMBA_PROJECT_PATH', File.expand_path('../Columba.xcodeproj', __dir__))
)
NE_TARGET = 'ColumbaNetworkExtension'
PRODUCTS = %w[ReticulumSwift LXMFSwift].freeze
PRODUCT_REPOSITORIES = {
  'ReticulumSwift' => 'https://github.com/torlando-tech/reticulum-swift.git',
  'LXMFSwift' => 'https://github.com/torlando-tech/LXMF-swift.git'
}.freeze

module NetworkExtensionBackendDependencies
  module_function

  def remove_uuid(list, uuid)
    index = list.each_with_index.find { |item, _position| item.uuid == uuid }&.last
    list.delete_at(index) if index
  end

  def dependency_owners(project, dependency)
    project.targets.select do |target|
      target.package_product_dependencies.any? { |candidate| candidate.uuid == dependency.uuid }
    end
  end

  def build_file_owners(project, build_file)
    project.objects.grep(Xcodeproj::Project::Object::AbstractBuildPhase).select do |phase|
      phase.files.any? { |candidate| candidate.uuid == build_file.uuid }
    end
  end

  def dependency_build_files(project, dependency)
    project.objects.grep(Xcodeproj::Project::Object::PBXBuildFile).select do |build_file|
      build_file.product_ref&.uuid == dependency.uuid
    end
  end

  def package_for(project, product_name)
    repository_url = PRODUCT_REPOSITORIES.fetch(product_name)
    matches = project.root_object.package_references.select do |reference|
      reference.is_a?(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference) &&
        reference.repositoryURL.to_s == repository_url
    end
    unless matches.length == 1
      raise "expected exactly one root package reference for #{product_name} at #{repository_url}; " \
            "found #{matches.length}"
    end

    matches.first
  end

  def reconcile_product(project, extension, product_name)
    framework_phase = extension.frameworks_build_phase
    root_package = package_for(project, product_name)
    candidates = extension.package_product_dependencies.select do |dependency|
      dependency.product_name == product_name
    end
    dependency = candidates.find do |candidate|
      candidate.package&.uuid == root_package.uuid &&
        dependency_owners(project, candidate).map(&:uuid) == [extension.uuid] &&
        dependency_build_files(project, candidate).all? do |build_file|
          build_file_owners(project, build_file).map(&:uuid) == [framework_phase.uuid]
        end
    end

    unless dependency
      dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
      dependency.package = root_package
      dependency.product_name = product_name
      extension.package_product_dependencies << dependency
    end

    matching_files = framework_phase.files.select do |build_file|
      build_file.product_ref&.uuid == dependency.uuid &&
        build_file_owners(project, build_file).map(&:uuid) == [framework_phase.uuid]
    end
    retained_file = matching_files.first
    unless retained_file
      retained_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
      retained_file.product_ref = dependency
      framework_phase.files << retained_file
    end

    extension.build_phases.each do |phase|
      phase.files.dup.each do |build_file|
        next if phase.uuid == framework_phase.uuid && build_file.uuid == retained_file.uuid
        next unless build_file.product_ref&.product_name == product_name

        remove_uuid(phase.files, build_file.uuid)
        build_file.remove_from_project if build_file_owners(project, build_file).empty?
      end
    end

    extension.package_product_dependencies.dup.each do |stale|
      next if stale.uuid == dependency.uuid || stale.product_name != product_name

      remove_uuid(extension.package_product_dependencies, stale.uuid)
      if dependency_owners(project, stale).empty? && dependency_build_files(project, stale).empty?
        stale.remove_from_project
      end
    end

    puts "  = #{product_name} is target-local on #{NE_TARGET}"
  end
end

project = Xcodeproj::Project.open(PROJECT_PATH)
extension = project.targets.find { |target| target.name == NE_TARGET } or
  abort "Missing #{NE_TARGET} target"
PRODUCTS.each do |product_name|
  NetworkExtensionBackendDependencies.reconcile_product(project, extension, product_name)
end
project.save
Xcodeproj::Project.open(PROJECT_PATH)
puts "Saved #{PROJECT_PATH} (only #{NE_TARGET} was reconciled)"
