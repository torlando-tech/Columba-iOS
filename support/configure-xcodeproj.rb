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

# Phase 0 deleted the voice stack while ripping out the AI Swift libs;
# commit 3 of the lxst-wiring batch restored these files from git history
# (rewired onto RNSAPI + LXSTSwift). Tests-side voice files stay out — the
# test fixtures referenced AI types that aren't part of the new world.
DELETED_PATHS = %w[
  Tests/ColumbaAppTests/CallManagerCallKitTests.swift
  Tests/ColumbaAppTests/AudioManagerConfigChangeTests.swift
  Tests/ColumbaAppTests/AudioRingBufferTests.swift
].freeze

deleted_basenames = DELETED_PATHS.map { |p| File.basename(p) }

# General garbage-collect: nuke any file ref whose target no longer exists on
# disk (covers files moved/renamed/deleted outside Phase 0). Skip the
# xcframework + the `app` folder ref + anything outside the repo root.
project_root = File.expand_path('..', __dir__)

removed = []
project.files.dup.each do |f|
  basename = File.basename(f.path.to_s)
  abs = f.real_path.to_s rescue ''
  is_dead =
    deleted_basenames.include?(basename) ||
    (
      !abs.empty? &&
      abs.start_with?(project_root) &&
      f.path != 'Frameworks/Python.xcframework' &&
      f.path != 'app' &&
      !File.exist?(abs)
    )
  next unless is_dead
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
puts "  Removed #{removed.size} dead file refs" unless removed.empty?

# ──────────────────────────────────────────────────────────────────────────
# (2) Drop SwiftPM remote refs for reticulum-swift / LXMF-swift / LXST-swift.
# ──────────────────────────────────────────────────────────────────────────

drop_pkg_urls = [
  'https://github.com/torlando-tech/reticulum-swift.git',
  'https://github.com/torlando-tech/LXMF-swift.git',
  'https://github.com/torlando-tech/LXST-swift.git'
]

# NOTE: LXSTSwift is no longer in this drop list — it's now a LOCAL
# SwiftPM target inside this repo (declared in Package.swift,
# dependencies path-based), and gets re-added below via the local-
# package reference path.
drop_product_names = %w[ReticulumSwift LXMFSwift]

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

# Add a local Swift Package reference to the repo root, exposing the
# LXSTSwift target (and its C dependencies COpus + CCodec2). Xcode
# treats the root Package.swift as a sibling package and compiles its
# products into the app target. This dodges the per-file pbxproj
# surgery that would otherwise be needed for ~380 C source files
# under Sources/{COpus, CCodec2}/.
local_pkg_class = Xcodeproj::Project::Object.const_get('XCLocalSwiftPackageReference') rescue nil
if local_pkg_class
  # Some xcodeproj-gem versions don't ship XCLocalSwiftPackageReference;
  # detect and warn so we can fall back to manual surgery if needed.
  existing_local = project.root_object.package_references.find do |p|
    p.is_a?(local_pkg_class) && (p.respond_to?(:relative_path) ? p.relative_path : nil) == '.'
  end
  unless existing_local
    local_pkg = project.new(local_pkg_class)
    local_pkg.relative_path = '.'
    project.root_object.package_references << local_pkg
    puts "  Added local SPM package reference: ."
  end
  unless app_target.package_product_dependencies.any? { |d| d.product_name == 'LXSTSwift' }
    product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    product.product_name = 'LXSTSwift'
    app_target.package_product_dependencies << product
    bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    bf.product_ref = product
    app_target.frameworks_build_phase.files << bf
    puts "  Linked product: LXSTSwift (local)"
  end
  # RNSAPI: same story as LXSTSwift — compiled exactly once by SwiftPM and
  # exposed to ColumbaApp as a product dependency. Without this, the
  # `Sources/RNSAPI/**/*.swift` files that USED to be inlined into the
  # ColumbaApp build phase would have to stay there, and every shared
  # type would exist in both modules. See the NEW_SWIFT note.
  unless app_target.package_product_dependencies.any? { |d| d.product_name == 'RNSAPI' }
    product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    product.product_name = 'RNSAPI'
    app_target.package_product_dependencies << product
    bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    bf.product_ref = product
    app_target.frameworks_build_phase.files << bf
    puts "  Linked product: RNSAPI (local)"
  end
else
  puts "  WARNING: xcodeproj gem doesn't support XCLocalSwiftPackageReference; skip local-pkg wiring"
end

# Strip any leftover Sources/RNSAPI/*.swift file refs that an earlier run
# of this script had added to ColumbaApp's compile phase. They have to come
# out now that RNSAPI is a SwiftPM product dependency — otherwise every
# shared type exists in two modules and call sites fail with "cannot
# convert value of type 'ColumbaApp.Identity' to 'RNSAPI.Identity'".
stale_rnsapi_count = 0
app_target.source_build_phase.files.dup.each do |bf|
  path = bf.file_ref&.real_path&.to_s
  next unless path && path.include?('/Sources/RNSAPI/')
  bf.remove_from_project
  stale_rnsapi_count += 1
end
project.files.dup.each do |f|
  abs = f.real_path.to_s rescue ''
  next unless abs.include?('/Sources/RNSAPI/')
  f.remove_from_project
end
puts "  Stripped #{stale_rnsapi_count} RNSAPI inline source ref(s) from ColumbaApp" if stale_rnsapi_count > 0

# ──────────────────────────────────────────────────────────────────────────
# (3) Add new Sources/ColumbaApp/Python/ files to Sources build phase.
# ──────────────────────────────────────────────────────────────────────────

# Auto-discover all .swift sources under the new Sources/{PythonBridge,RNSAPI,RNSBackendPy}/
# trees. These are SwiftPM library targets per Package.swift, but the Xcode
# build of ColumbaApp.app pulls them in as plain sources of the ColumbaApp
# target (because Xcode's app target isn't SwiftPM-based and adding them as
# SPM products would require a much larger pbxproj surgery). The Package.swift
# split is preserved for tooling (`swift build`, lint, code search) and for
# when we eventually move ColumbaApp onto SwiftPM.
project_root = File.expand_path('..', __dir__)
# NOTE: Sources/RNSAPI/ is NOT in this list. RNSAPI is compiled exactly once
# by SwiftPM via the XCLocalSwiftPackageReference below; ColumbaApp imports
# it as a SwiftPM product dependency. If we also added the .swift files to
# the ColumbaApp build phase, every type in RNSAPI would exist in two
# modules ('RNSAPI' from the framework + 'ColumbaApp' from inline compile)
# and call sites like `Telephone(identity: someIdentity)` would fail with
# "cannot convert value of type 'ColumbaApp.Identity' to expected argument
# type 'RNSAPI.Identity'".
NEW_SWIFT = (
  Dir.glob("#{project_root}/Sources/PythonBridge/**/*.swift") +
  Dir.glob("#{project_root}/Sources/RNSBackendPy/**/*.swift") +
  Dir.glob("#{project_root}/Sources/ColumbaApp/Views/Call/*.swift") +
  %w[
    Sources/ColumbaApp/Python/Models/PyAnnounce.swift
    Sources/ColumbaApp/Python/Models/PyMessage.swift
    Sources/ColumbaApp/Python/Models/PyConversation.swift
    Sources/ColumbaApp/Python/Models/PyLocalIdentity.swift
    Sources/ColumbaApp/Services/PythonConfigWriter.swift
    Sources/ColumbaApp/Services/CallManager.swift
    Sources/ColumbaApp/Services/CallKitManager.swift
    Sources/ColumbaApp/Services/AudioManager.swift
    Sources/ColumbaApp/Models/CodecProfileInfo.swift
  ].map { |p| File.expand_path(p, project_root) }
).uniq.map { |p| p.sub("#{project_root}/", '') }.sort.freeze

# Place under a "Python" group inside the existing ColumbaApp group. The
# hand-written pbxproj attaches the ColumbaApp group (SRCS) directly to
# main_group with path "Sources/ColumbaApp" — so find_subpath('Sources/ColumbaApp')
# fails to match and would create a brand-new tree. Find it by path instead.
columba_group = project.main_group.children.find do |g|
  g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == 'Sources/ColumbaApp'
end
abort "Could not locate Sources/ColumbaApp group in main_group" unless columba_group

# Find or create top-level groups for the new SwiftPM-style targets so the
# Xcode navigator shows them outside the ColumbaApp/ tree.
def find_or_create_top_group(project, name)
  existing = project.main_group.children.find do |g|
    g.is_a?(Xcodeproj::Project::Object::PBXGroup) &&
      (g.name == name || g.path == "Sources/#{name}")
  end
  return existing if existing
  group = project.main_group.new_group(name, "Sources/#{name}")
  group.set_source_tree('<group>')
  group
end

python_bridge_group = find_or_create_top_group(project, 'PythonBridge')
rns_api_group       = find_or_create_top_group(project, 'RNSAPI')
rns_backend_py_group = find_or_create_top_group(project, 'RNSBackendPy')

# Old ColumbaApp/Python/Models — kept for now; PyAnnounce etc. will collapse
# into RNSAPI/Models in a later commit.
columba_python_group = columba_group.children.find { |g| g.respond_to?(:name) && g.name == 'Python' } ||
                       columba_group.new_group('Python').tap { |g| g.set_source_tree('<group>') }
columba_python_models_group = columba_python_group.children.find { |g| g.respond_to?(:name) && g.name == 'Models' } ||
                              columba_python_group.new_group('Models').tap { |g| g.set_source_tree('<group>') }

existing_paths = app_target.source_build_phase.files.map { |bf| bf.file_ref&.real_path&.to_s }

NEW_SWIFT.each do |rel|
  full = File.expand_path(rel, File.dirname(PROJECT_PATH))
  next if existing_paths.include?(full)
  group =
    if rel.start_with?('Sources/PythonBridge/')
      python_bridge_group
    elsif rel.start_with?('Sources/RNSAPI/')
      # nest under Protocols/Models/Util subgroups for navigability
      sub_name = rel.split('/')[2]   # "Protocols" | "Models" | "Util"
      next_group = rns_api_group.children.find { |g| g.respond_to?(:name) && g.name == sub_name } ||
                   rns_api_group.new_group(sub_name).tap { |g| g.set_source_tree('<group>') }
      next_group
    elsif rel.start_with?('Sources/RNSBackendPy/')
      rns_backend_py_group
    elsif rel.include?('/ColumbaApp/Python/Models/')
      columba_python_models_group
    elsif rel.include?('/ColumbaApp/Python/')
      columba_python_group
    elsif rel.start_with?('Sources/ColumbaApp/Services/')
      services_group = columba_group.children.find { |g| g.respond_to?(:name) && (g.name == 'Services' || g.path == 'Services') } ||
                       columba_group.new_group('Services').tap { |g| g.set_source_tree('<group>') }
      services_group
    elsif rel.start_with?('Sources/ColumbaApp/Views/Call/')
      views_group = columba_group.children.find { |g| g.respond_to?(:name) && (g.name == 'Views' || g.path == 'Views') } ||
                    columba_group.new_group('Views').tap { |g| g.set_source_tree('<group>') }
      call_group = views_group.children.find { |g| g.respond_to?(:name) && (g.name == 'Call' || g.path == 'Call') } ||
                   views_group.new_group('Call').tap { |g| g.set_source_tree('<group>') }
      call_group
    elsif rel.start_with?('Sources/ColumbaApp/Models/')
      models_group = columba_group.children.find { |g| g.respond_to?(:name) && (g.name == 'Models' || g.path == 'Models') } ||
                     columba_group.new_group('Models').tap { |g| g.set_source_tree('<group>') }
      models_group
    else
      columba_group
    end
  ref = group.new_file(full)
  app_target.source_build_phase.add_file_reference(ref)
  puts "  Added source: #{rel}"
end

# Bridging header — file ref only, no build phase membership. Moved from
# ColumbaApp/Python/ to PythonBridge/ — register at the new location.
bridging_path = 'Sources/PythonBridge/ColumbaPython-Bridging-Header.h'
bridging_full = File.expand_path(bridging_path, File.dirname(PROJECT_PATH))
unless python_bridge_group.files.any? { |f| f.real_path.to_s == bridging_full }
  python_bridge_group.new_file(bridging_full)
  puts "  Added bridging header: #{bridging_path}"
end

# Update SWIFT_OBJC_BRIDGING_HEADER path to the new location.
app_target.build_configurations.each do |config|
  if config.build_settings['SWIFT_OBJC_BRIDGING_HEADER']&.include?('ColumbaApp/Python/')
    config.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = bridging_path
  end
end

# Bundled JetBrains Mono TTFs — needed for stable cell metrics on the Micron
# renderer (SF Mono renders block-element glyphs ▗▄▖▝▀▘ at slightly different
# widths than ASCII, which breaks ASCII-art alignment on NomadNet pages).
# See commit cf00c97 — the same fix Columba Android ships under
# MicronComposables.kt::JetBrainsMonoFamily.
resources_group = columba_group.children.find do |g|
  g.is_a?(Xcodeproj::Project::Object::PBXGroup) && (g.name == 'Resources' || g.path == 'Resources')
end || columba_group.new_group('Resources').tap { |g| g.set_source_tree('<group>') }

['JetBrainsMono-Regular.ttf', 'JetBrainsMono-Bold.ttf'].each do |ttf|
  rel = "Sources/ColumbaApp/Resources/#{ttf}"
  full = File.expand_path(rel, File.dirname(PROJECT_PATH))
  next unless File.exist?(full)
  ref = resources_group.files.find { |f| f.real_path.to_s == full } ||
        resources_group.new_file(full)
  unless app_target.resources_build_phase.files.any? { |bf| bf.file_ref == ref }
    app_target.resources_build_phase.add_file_reference(ref)
    puts "  Added resource: #{ttf}"
  end
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

bridging_relative = 'Sources/PythonBridge/ColumbaPython-Bridging-Header.h'
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
