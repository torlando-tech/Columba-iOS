#!/usr/bin/env ruby
# One application and one test host. Both process adapters ship in this artifact.
require 'xcodeproj'
require 'pathname'
project = Xcodeproj::Project.open(File.expand_path('../Columba.xcodeproj', __dir__))
# Older generated projects reused PBXBuildFile objects across targets.
project.targets.each do |target|
  target.build_phases.each do |phase|
    next unless phase.respond_to?(:files)
    phase.files.to_a.each do |file|
      next unless file.referrers.uniq.length > 1
      replacement = project.new(Xcodeproj::Project::Object::PBXBuildFile)
      replacement.file_ref = file.file_ref
      replacement.product_ref = file.product_ref
      replacement.settings = file.settings
      phase.files.delete(file)
      phase.files << replacement
    end
  end
end
app = project.targets.find { |t| t.name == 'ColumbaApp' }
ne = project.targets.find { |t| t.name == 'ColumbaNetworkExtension' }
tests = project.targets.find { |t| t.name == 'ColumbaAppTests' }
model = project.targets.find { |t| t.name == 'ColumbaModelBApp' }
model_tests = project.targets.find { |t| t.name == 'ColumbaModelBAppTests' }
def add_source(target, ref)
  target.source_build_phase.add_file_reference(ref) unless target.source_build_phase.files_references.include?(ref)
end
if model
  model.source_build_phase.files_references.each { |ref| add_source(app, ref) }
  model.copy_files_build_phases.each do |phase|
    next unless phase.name == 'Embed App Extensions'
    copy = app.copy_files_build_phases.find { |p| p.name == phase.name } || app.new_copy_files_build_phase(phase.name)
    copy.dst_subfolder_spec = phase.dst_subfolder_spec
    phase.files.each { |f| copy.add_file_reference(f.file_ref).settings = f.settings unless copy.files_references.include?(f.file_ref) }
  end
end
app.add_dependency(ne) unless app.dependencies.any? { |d| d.target == ne }
model_tests&.source_build_phase&.files_references&.each { |ref| add_source(tests, ref) }
# Replace legacy embedded runtime with the engine shared by the two process hosts.
legacy = %w[ModelBBLEService.swift PyAnnounce.swift PyConversation.swift PyMessage.swift PyLocalIdentity.swift BackendPreference.swift PythonRuntime.swift PythonBridge.swift PythonBLECallbackBridge.swift PythonRNSBackend.swift SwiftRNSBackend.swift]
app.source_build_phase.files.to_a.each { |f| f.remove_from_project if legacy.include?(File.basename(f.file_ref.path)) }
renames = {
  'ModelBNetworkTransport.swift' => 'Sources/ColumbaApp/Services/NodeNetworkTransport.swift',
  'ModelBInboundReplay.swift' => 'Sources/ColumbaApp/Services/NodeInboundReplay.swift',
  'PythonNetworkTransport.swift' => 'Sources/ColumbaApp/Services/ColumbaLXSTTransport.swift',
  'PythonRNodeBLEBridge.swift' => 'Sources/RNSHost/PythonRNodeBLEBridge.swift',
  'NEPythonRuntime.swift' => 'Sources/RNSHost/PythonNodeRuntime.swift',
  'NEPythonRNS.swift' => 'Sources/RNSHost/PythonNodeEngine.swift',
  'NEBLECABIBridge.swift' => 'Sources/RNSHost/PythonNodeBLEBridge.swift',
  'ColumbaNEPython-Bridging-Header.h' => 'Sources/RNSHost/PythonNode-Bridging-Header.h'
}
project.files.each do |ref|
  path = renames[File.basename(ref.path.to_s)]
  next unless path
  ref.path = path
  ref.name = File.basename(path)
  ref.source_tree = 'SOURCE_ROOT'
end
shared_paths = Dir.glob('Sources/RNSHost/*.swift') + ['Sources/Shared/NodeHostingMode.swift', 'Sources/Shared/NodeStateMigration.swift', 'Sources/Shared/OutboxEntry.swift']
shared_paths.each do |path|
  ref = project.files.find { |f| f.real_path.to_s == File.join(project.project_dir.to_s, path) } || project.main_group.new_file(path)
  add_source(app, ref)
  add_source(ne, ref) unless path.end_with?('LocalNodeAdapter.swift')
end
Dir.glob('Tests/ColumbaAppTests/*.swift').each do |path|
  ref = project.files.find { |f| f.real_path.to_s.end_with?(path) } || project.main_group.new_file(path)
  add_source(tests, ref)
end
# Types shared by the app's voice adapter.
path = 'Sources/ColumbaApp/Services/ColumbaLXSTTransport.swift'
add_source(app, project.files.find { |f| f.real_path.to_s.end_with?(path) })
[app, tests].each do |target|
  target.build_configurations.each do |config|
    config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) COLUMBA_ONBOARDING_ENABLED COLUMBA_MIGRATION_ENABLED COLUMBA_RNODE_ENABLED'
  end
end
[app, ne].each do |target|
  target.build_configurations.each do |c|
    c.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'Sources/RNSHost/PythonNode-Bridging-Header.h'
    # Python's resource installer expects one lib-<arch> directory. Both hosts
    # must match the arm64 simulator wheels shipped by this project.
    c.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'x86_64'
  end
end
project.targets.flat_map { |t| t.source_build_phase.files_references }.uniq.each do |ref|
  absolute = ref.real_path.to_s
  ref.path = Pathname.new(absolute).relative_path_from(project.project_dir).to_s
  ref.source_tree = 'SOURCE_ROOT'
  ref.referrers.grep(Xcodeproj::Project::Object::PBXGroup).each { |g| g.children.delete(ref) }; project.main_group.children << ref
end
[model_tests, model].compact.each(&:remove_from_project)
project.targets.flat_map { |t| t.source_build_phase.files_references }.uniq.each { |ref| ref.referrers.grep(Xcodeproj::Project::Object::PBXGroup).each { |g| g.children.delete(ref) }; project.main_group.children << ref }
obsolete_names = %w[ModelBBLEService.swift BackendPreference.swift PythonRuntime.swift PythonBridge.swift PythonBLECallbackBridge.swift PythonRNSBackend.swift ColumbaPython-Bridging-Header.h PyAnnounce.swift PyConversation.swift PyMessage.swift PyLocalIdentity.swift ColumbaModelBApp.app ColumbaModelBAppTests.xctest]
project.files.to_a.each { |ref| ref.remove_from_project if obsolete_names.include?(File.basename(ref.path.to_s)) }
project.save
