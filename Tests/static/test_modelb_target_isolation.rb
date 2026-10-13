#!/usr/bin/env ruby
# Historical filename retained for callers; the contract is now one shipping app.
require 'minitest/autorun'
require 'xcodeproj'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'

class UnifiedHostingProjectTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  def setup
    @project = Xcodeproj::Project.open(File.join(ROOT, 'Columba.xcodeproj'))
  end
  def paths(target)
    target.source_build_phase.files_references.map { |r| r.real_path.relative_path_from(@project.project_dir).to_s }
  end
  def test_single_app_and_test_host
    assert_equal %w[ColumbaApp ColumbaAppTests ColumbaNetworkExtension], @project.targets.map(&:name).sort
    %w[ColumbaApp ColumbaAppTests].each do |name|
      @project.targets.find { |t| t.name == name }.build_configurations.each do |c|
        refute_match(/COLUMBA_RUNTIME_|COLUMBA_BACKEND_|ENABLE_NETWORK_EXTENSION/, c.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'].to_s)
      end
    end
  end
  def test_python_hosts_use_the_same_single_simulator_architecture
    %w[ColumbaApp ColumbaNetworkExtension].each do |name|
      @project.targets.find { |t| t.name == name }.build_configurations.each do |c|
        assert_equal 'x86_64', c.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'], "#{name} #{c.name}"
      end
    end
  end
  def test_shared_engine_and_adapter_boundary
    app = @project.targets.find { |t| t.name == 'ColumbaApp' }
    ne = @project.targets.find { |t| t.name == 'ColumbaNetworkExtension' }
    %w[PythonNodeEngine PythonNodeRuntime NodeCommandDispatcher NodeHostObservers NodeProcessLease].each do |name|
      [app, ne].each { |t| assert_includes paths(t), "Sources/RNSHost/#{name}.swift" }
    end
    assert_includes paths(app), 'Sources/RNSHost/LocalNodeAdapter.swift'
    refute_includes paths(ne), 'Sources/RNSHost/LocalNodeAdapter.swift'
    refute paths(app).any? { |p| p.match?(/PythonRNSBackend|SwiftRNSBackend|PythonBridge.swift|ModelBBLEService/) }
    assert app.dependencies.any? { |d| d.target == ne }
    embed = app.copy_files_build_phases.find { |p| p.name == 'Embed App Extensions' }
    refute_nil embed
    assert embed.files.any? { |f| f.file_ref == ne.product_reference && f.settings.fetch('ATTRIBUTES', []).include?('CodeSignOnCopy') }
  end
  def test_extension_links_python_without_embedding_another_payload
    ne = @project.targets.find { |t| t.name == 'ColumbaNetworkExtension' }
    refute ne.copy_files_build_phases.any? { |p| p.files_references.any? { |f| f.path.to_s.include?('Python.xcframework') } }
    refute ne.shell_script_build_phases.any? { |p| p.shell_script.include?('install_python') || p.shell_script.include?('codesign --force') }
    ne.build_configurations.each do |c|
      assert_includes Array(c.build_settings['LD_RUNPATH_SEARCH_PATHS']), '@executable_path/../../Frameworks'
    end
  end
  def test_incremental_cleanup_is_scoped_to_generated_extension_payload
    ne = @project.targets.find { |t| t.name == 'ColumbaNetworkExtension' }
    phase = ne.shell_script_build_phases.find { |p| p.name == 'Remove obsolete extension Python payload' }
    refute_nil phase
    Dir.mktmpdir('columba-extension-cleanup') do |dir|
      product = File.join(dir, 'ColumbaNetworkExtension.appex')
      FileUtils.mkdir_p(product)
      %w[app app_packages python Frameworks].each { |p| FileUtils.mkdir_p(File.join(product, p)); File.write(File.join(product, p, 'old.py'), 'old') }
      File.write(File.join(product, 'Info.plist'), 'metadata')
      File.write(File.join(product, 'ColumbaNetworkExtension'), 'executable')
      2.times do
        output, status = Open3.capture2e({'CODESIGNING_FOLDER_PATH' => product}, 'sh', '-c', phase.shell_script)
        assert status.success?, output
      end
      assert_equal %w[ColumbaNetworkExtension Info.plist], Dir.children(product).sort
      output, status = Open3.capture2e({'CODESIGNING_FOLDER_PATH' => dir}, 'sh', '-c', phase.shell_script)
      refute status.success?, output
      assert File.exist?(File.join(product, 'Info.plist'))
    end
  end
  def test_source_paths_exist_and_are_unique
    @project.targets.each do |target|
      files = target.source_build_phase.files_references.map { |r| r.real_path.to_s }
      assert_equal files.uniq, files
      files.each { |p| assert File.file?(p), "Missing #{p}" }
    end
  end
  def test_reconciliation_is_idempotent
    Dir.mktmpdir('columba-project-contract') do |dir|
      FileUtils.cp_r(File.join(ROOT, 'Columba.xcodeproj'), dir)
      FileUtils.cp_r(File.join(ROOT, 'support'), dir)
      %w[Sources Tests].each { |name| FileUtils.ln_s(File.join(ROOT, name), File.join(dir, name)) }
      script = File.join(dir, 'support/configure-unified-hosting.rb')
      2.times do |i|
        output, status = Open3.capture2e('ruby', script, chdir: dir)
        assert status.success?, output
        digest = Digest::SHA256.file(File.join(dir, 'Columba.xcodeproj/project.pbxproj')).hexdigest
        assert_equal @digest, digest if i == 1
        @digest = digest
      end
    end
  end
end
