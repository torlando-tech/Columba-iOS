#!/usr/bin/env ruby
# Configure Columba.xcodeproj for the embedded-Python build.
#
# Idempotent: safe to re-run after the initial setup. Edits the ColumbaApp
# target to:
#   1. Remove file references to voice files deleted in Phase 0 (CallManager,
#      AudioManager, CodecProfileInfo, Views/Call/*, voice tests).
#   2. Remove SwiftPM remote refs for reticulum-swift / LXMF-swift / LXST-swift,
#      and the product refs that pulled them in.
#   3. Add the new Sources/ColumbaApp/Python/ files
#      (PythonRuntime.swift, PythonBridge.swift, Models/*.swift) to the
#      Sources build phase. The bridging header lands as a file ref only
#      (not in any build phase).
#   4. Link + embed Frameworks/Python.xcframework with codesigning on copy.
#   5. Add a Run Script build phase that invokes
#      Frameworks/Python.xcframework/build/utils.sh::install_python to
#      install the stdlib and convert each .so into a per-module .framework.
#   6. Add folder references for `app/` and `app_packages/` as resource
#      copies (the build phase script expects them at <bundle>/app and
#      <bundle>/app_packages respectively).
#   7. Add the bridging header + EXCLUDED_ARCHS[sdk=iphonesimulator*]=x86_64 +
#      ONLY_ACTIVE_ARCH=YES build settings (the latter two work around the
#      install_python script's fat-simulator-build bug).

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Columba.xcodeproj', __dir__)
project = Xcodeproj::Project.open(PROJECT_PATH)

app_target = project.targets.find { |t| t.name == 'ColumbaApp' }
abort "Missing ColumbaApp target" unless app_target

test_target = project.targets.find { |t| t.name == 'ColumbaAppTests' }

# ──────────────────────────────────────────────────────────────────────────
# (1) Remove file refs to voice files deleted in Phase 0.
# ──────────────────────────────────────────────────────────────────────────

DELETED_PATHS = %w[
  Sources/ColumbaApp/Services/CallManager.swift
  Sources/ColumbaApp/Services/CallKitManager.swift
  Sources/ColumbaApp/Services/AudioManager.swift
  Sources/ColumbaApp/Models/CodecProfileInfo.swift
  Sources/ColumbaApp/Views/Call/CallControlButton.swift
  Sources/ColumbaApp/Views/Call/CodecSelectionSheet.swift
  Sources/ColumbaApp/Views/Call/IncomingCallScreen.swift
  Sources/ColumbaApp/Views/Call/PttButton.swift
  Sources/ColumbaApp/Views/Call/VoiceCallScreen.swift
  Tests/ColumbaAppTests/CallManagerCallKitTests.swift
  Tests/ColumbaAppTests/AudioManagerConfigChangeTests.swift
  Tests/ColumbaAppTests/AudioRingBufferTests.swift
].freeze

deleted_basenames = DELETED_PATHS.map { |p| File.basename(p) }

removed = []
project.files.dup.each do |f|
  next unless deleted_basenames.include?(File.basename(f.path.to_s))
  # Detach from all build phases first.
  [app_target, test_target].compact.each do |t|
    t.build_phases.each do |phase|
      next unless phase.respond_to?(:files)
      phase.files.dup.each { |bf| bf.remove_from_project if bf.file_ref == f }
    end
  end
  removed << f.path
  f.remove_from_project
end
puts "  Removed #{removed.size} dead file refs: #{removed.join(', ')}" unless removed.empty?

# ──────────────────────────────────────────────────────────────────────────
# (2) Drop SwiftPM remote refs for reticulum-swift / LXMF-swift / LXST-swift.
# ──────────────────────────────────────────────────────────────────────────

drop_pkg_urls = [
  'https://github.com/torlando-tech/reticulum-swift.git',
  'https://github.com/torlando-tech/LXMF-swift.git',
  'https://github.com/torlando-tech/LXST-swift.git'
]

drop_product_names = %w[ReticulumSwift LXMFSwift LXSTSwift]

# Remove products from target (frameworks build phase + package_product_dependencies).
app_target.package_product_dependencies.dup.each do |dep|
  next unless drop_product_names.include?(dep.product_name)
  # Strip from PBXFrameworksBuildPhase
  app_target.frameworks_build_phase.files.dup.each do |bf|
    bf.remove_from_project if bf.product_ref == dep
  end
  app_target.package_product_dependencies.delete(dep)
  dep.remove_from_project
  puts "  Removed package product dep: #{dep.product_name}"
end

# Remove remote SPM package references from the project.
project.root_object.package_references.dup.each do |pkg|
  next unless pkg.is_a?(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  if drop_pkg_urls.include?(pkg.repositoryURL)
    project.root_object.package_references.delete(pkg)
    pkg.remove_from_project
    puts "  Removed SPM package: #{pkg.repositoryURL}"
  end
end

# ──────────────────────────────────────────────────────────────────────────
# (3) Add new Sources/ColumbaApp/Python/ files to Sources build phase.
# ──────────────────────────────────────────────────────────────────────────

NEW_SWIFT = %w[
  Sources/ColumbaApp/Python/PythonRuntime.swift
  Sources/ColumbaApp/Python/PythonBridge.swift
  Sources/ColumbaApp/Python/Models/PyAnnounce.swift
  Sources/ColumbaApp/Python/Models/PyMessage.swift
  Sources/ColumbaApp/Python/Models/PyConversation.swift
  Sources/ColumbaApp/Python/Models/PyLocalIdentity.swift
].freeze

# Place under a "Python" group inside the existing ColumbaApp group. The
# hand-written pbxproj attaches the ColumbaApp group (SRCS) directly to
# main_group with path "Sources/ColumbaApp" — so find_subpath('Sources/ColumbaApp')
# fails to match and would create a brand-new tree. Find it by path instead.
columba_group = project.main_group.children.find do |g|
  g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == 'Sources/ColumbaApp'
end
abort "Could not locate Sources/ColumbaApp group in main_group" unless columba_group

python_group = columba_group.children.find { |g| g.respond_to?(:name) && g.name == 'Python' }
unless python_group
  python_group = columba_group.new_group('Python')
  python_group.set_source_tree('<group>')
end
models_group = python_group.children.find { |g| g.respond_to?(:name) && g.name == 'Models' }
unless models_group
  models_group = python_group.new_group('Models')
  models_group.set_source_tree('<group>')
end

existing_paths = app_target.source_build_phase.files.map { |bf| bf.file_ref&.real_path&.to_s }

NEW_SWIFT.each do |rel|
  full = File.expand_path(rel, File.dirname(PROJECT_PATH))
  next if existing_paths.include?(full)
  group = rel.include?('/Models/') ? models_group : python_group
  ref = group.new_file(full)
  app_target.source_build_phase.add_file_reference(ref)
  puts "  Added source: #{rel}"
end

# Bridging header — file ref only, no build phase membership.
bridging_path = 'Sources/ColumbaApp/Python/ColumbaPython-Bridging-Header.h'
bridging_full = File.expand_path(bridging_path, File.dirname(PROJECT_PATH))
unless python_group.files.any? { |f| f.real_path.to_s == bridging_full }
  python_group.new_file(bridging_full)
  puts "  Added bridging header: #{bridging_path}"
end

# ──────────────────────────────────────────────────────────────────────────
# (4) Link + embed Frameworks/Python.xcframework.
# ──────────────────────────────────────────────────────────────────────────

xcfw_path = 'Frameworks/Python.xcframework'
# Find or create the project-level Frameworks group (the existing pbxproj
# doesn't have one; create it as a child of main_group).
frameworks_group = project.main_group.children.find do |g|
  g.is_a?(Xcodeproj::Project::Object::PBXGroup) &&
    (g.path == 'Frameworks' || g.name == 'Frameworks')
end
unless frameworks_group
  frameworks_group = project.main_group.new_group('Frameworks')
  frameworks_group.set_source_tree('<group>')
end

xcfw_ref = frameworks_group.files.find { |f| f.path == xcfw_path } ||
           frameworks_group.new_file(File.expand_path(xcfw_path, File.dirname(PROJECT_PATH)))

# Link.
unless app_target.frameworks_build_phase.files.any? { |bf| bf.file_ref == xcfw_ref }
  app_target.frameworks_build_phase.add_file_reference(xcfw_ref)
  puts "  Linked Python.xcframework"
end

# Embed (copy + codesign).
embed_phase = app_target.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :frameworks } ||
              app_target.new_copy_files_build_phase('Embed Frameworks').tap do |p|
                p.symbol_dst_subfolder_spec = :frameworks
              end
unless embed_phase.files.any? { |bf| bf.file_ref == xcfw_ref }
  bf = embed_phase.add_file_reference(xcfw_ref)
  bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
  puts "  Embedded Python.xcframework with codesign-on-copy"
end

# ──────────────────────────────────────────────────────────────────────────
# (5) Run Script build phase: install_python.
# ──────────────────────────────────────────────────────────────────────────

INSTALL_SCRIPT_NAME = 'Install Python stdlib & process dylibs'
INSTALL_SCRIPT_BODY = <<~SH.strip
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
  mkdir -p "$CODESIGNING_FOLDER_PATH/app_packages"
  rsync -au --delete "$WHEELS_SRC/" "$CODESIGNING_FOLDER_PATH/app_packages/"

  source "$PROJECT_DIR/Frameworks/Python.xcframework/build/utils.sh"
  install_python Frameworks/Python.xcframework app_packages
SH

install_phase = app_target.shell_script_build_phases.find { |p| p.name == INSTALL_SCRIPT_NAME } ||
                app_target.new_shell_script_build_phase(INSTALL_SCRIPT_NAME)
install_phase.shell_script = INSTALL_SCRIPT_BODY
install_phase.shell_path = '/bin/sh'
install_phase.input_paths = ['$(PROJECT_DIR)/Frameworks/Python.xcframework/build/utils.sh']
install_phase.output_paths = []
install_phase.show_env_vars_in_log = '0'
install_phase.always_out_of_date = '1'   # rerun every build (wheels can change)
puts "  Configured Run Script: #{INSTALL_SCRIPT_NAME}"

# ──────────────────────────────────────────────────────────────────────────
# (6) Folder references for app/ (Python source) and app_packages/.
# ──────────────────────────────────────────────────────────────────────────
#
# `app_packages/` is populated by the install_python script at build time,
# so it doesn't need a folder reference. `app/` ships rns_bridge.py plus
# any future Python modules and DOES need to be copied to <bundle>/app/.

app_folder_path = File.expand_path('../app', __dir__)
app_folder_ref = project.main_group.files.find { |f| f.path == 'app' && f.last_known_file_type == 'folder' }
unless app_folder_ref
  app_folder_ref = project.main_group.new_reference(app_folder_path)
  app_folder_ref.last_known_file_type = 'folder'
  app_folder_ref.set_source_tree('<group>')
  puts "  Added app/ folder reference"
end

unless app_target.resources_build_phase.files.any? { |bf| bf.file_ref == app_folder_ref }
  app_target.resources_build_phase.add_file_reference(app_folder_ref)
  puts "  Added app/ to Copy Bundle Resources"
end

# ──────────────────────────────────────────────────────────────────────────
# (7) Build settings: bridging header, EXCLUDED_ARCHS, ONLY_ACTIVE_ARCH.
# ──────────────────────────────────────────────────────────────────────────

bridging_relative = 'Sources/ColumbaApp/Python/ColumbaPython-Bridging-Header.h'
app_target.build_configurations.each do |config|
  config.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = bridging_relative
  config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
  # install_python's lib-$ARCHS path fails when ARCHS is multi-arch ("arm64 x86_64").
  # Force single-arch on simulator to dodge the bug.
  config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'x86_64'
  config.build_settings['ONLY_ACTIVE_ARCH'] = 'YES' if config.name == 'Debug'
  # Don't strip Python's stdlib symlinks.
  config.build_settings['COPY_PHASE_STRIP'] = 'NO'
  # Make sure dyld can find the embedded framework at runtime.
  rpaths = config.build_settings['LD_RUNPATH_SEARCH_PATHS'] || []
  rpaths = [rpaths] unless rpaths.is_a?(Array)
  ['$(inherited)', '@executable_path/Frameworks'].each do |p|
    rpaths << p unless rpaths.include?(p)
  end
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = rpaths
end
puts "  Set bridging header + EXCLUDED_ARCHS + LD_RUNPATH_SEARCH_PATHS"

project.save
puts "\nColumba.xcodeproj configured."
