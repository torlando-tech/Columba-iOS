#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'rexml/document'
require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
PROJECT_PATH = File.join(ROOT, 'Columba.xcodeproj')
SCHEMES_PATH = File.join(PROJECT_PATH, 'xcshareddata', 'xcschemes')
MODEL_B_TEST_SOURCES = %w[
  Tests/ColumbaAppTests/BLESeamDriverTests.swift
  Tests/ColumbaAppTests/RNodeSeamTests.swift
].freeze

class Task9SchemeAndTestHostContractTests < Minitest::Test
  def setup
    @project = Xcodeproj::Project.open(PROJECT_PATH)
  end

  def unique_target(name)
    targets = @project.targets.select { |target| target.name == name }
    assert_equal 1, targets.size, "expected exactly one #{name} target"
    targets.first
  end

  def source_paths(target)
    root = Pathname.new(ROOT)
    target.source_build_phase.files.map do |build_file|
      build_file.file_ref.real_path.relative_path_from(root).to_s
    end
  end

  def scheme(name)
    path = File.join(SCHEMES_PATH, "#{name}.xcscheme")
    assert File.file?(path), "missing shared #{name} scheme"
    REXML::Document.new(File.read(path))
  end

  def build_references(document)
    REXML::XPath.match(document, '/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference')
  end

  def action_configuration(document, action)
    REXML::XPath.first(document, "/Scheme/#{action}").attributes['buildConfiguration']
  end

  def testable_names(document)
    REXML::XPath.match(document, '/Scheme/TestAction/Testables/TestableReference/BuildableReference')
                 .map { |reference| reference.attributes['BlueprintName'] }
  end

  def test_shared_scheme_names_are_authoritative
    assert_equal %w[Columba-ModelB.xcscheme Columba.xcscheme],
                 Dir.children(SCHEMES_PATH).select { |name| name.end_with?('.xcscheme') }.sort
  end

  def test_shipping_scheme_builds_only_shipping_app_with_shipping_configurations
    document = scheme('Columba')
    assert_equal ['ColumbaApp'], build_references(document).map { |reference| reference.attributes['BlueprintName'] }
    assert_equal ['ColumbaAppTests'], testable_names(document)
    assert_equal 'Debug', action_configuration(document, 'TestAction')
    assert_equal 'Debug', action_configuration(document, 'LaunchAction')
    assert_equal 'Debug', action_configuration(document, 'AnalyzeAction')
    assert_equal 'Release', action_configuration(document, 'ProfileAction')
    assert_equal 'Release', action_configuration(document, 'ArchiveAction')
  end

  def test_model_b_scheme_explicitly_builds_host_and_extension
    document = scheme('Columba-ModelB')
    references = build_references(document)
    assert_equal %w[ColumbaModelBApp ColumbaNetworkExtension],
                 references.map { |reference| reference.attributes['BlueprintName'] }
    extension = references.last.parent
    assert_equal 'YES', extension.attributes['buildForTesting']
    assert_equal 'YES', extension.attributes['buildForRunning']
    assert_equal 'YES', extension.attributes['buildForProfiling']
    assert_equal 'YES', extension.attributes['buildForArchiving']
    assert_equal 'YES', extension.attributes['buildForAnalyzing']
    assert_equal ['ColumbaModelBAppTests'], testable_names(document)
    assert_equal 'Debug', action_configuration(document, 'TestAction')
    assert_equal 'Debug', action_configuration(document, 'LaunchAction')
    assert_equal 'Release', action_configuration(document, 'ProfileAction')
  end

  def test_model_b_tests_have_an_isolated_model_b_host
    shipping = unique_target('ColumbaApp')
    shipping_tests = unique_target('ColumbaAppTests')
    model_b = unique_target('ColumbaModelBApp')
    model_b_tests = unique_target('ColumbaModelBAppTests')

    assert_empty source_paths(shipping_tests) & MODEL_B_TEST_SOURCES
    assert_equal MODEL_B_TEST_SOURCES, source_paths(model_b_tests)
    assert_equal [model_b.uuid], model_b_tests.dependencies.map { |dependency| dependency.target.uuid }
    refute_includes model_b_tests.dependencies.map { |dependency| dependency.target.uuid }, shipping.uuid

    model_b_by_name = {}
    model_b.build_configurations.each { |configuration| model_b_by_name[configuration.name] = configuration }
    assert_equal model_b_by_name.keys, model_b_tests.build_configurations.map(&:name)
    model_b_tests.build_configurations.each do |configuration|
      assert_match(%r{/ColumbaModelBApp\.app/.*/ColumbaModelBApp$}, configuration.build_settings.fetch('TEST_HOST'))
      assert_equal '$(TEST_HOST)', configuration.build_settings.fetch('BUNDLE_LOADER')
      assert_equal model_b_by_name.fetch(configuration.name).build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'],
                   configuration.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']
    end
  end

  def test_model_b_tests_import_the_model_b_module
    MODEL_B_TEST_SOURCES.each do |path|
      source = File.read(File.join(ROOT, path))
      assert_includes source, '@testable import ColumbaModelBApp'
      refute_includes source, '@testable import ColumbaApp'
    end
  end
end
