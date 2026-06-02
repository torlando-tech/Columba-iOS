#!/usr/bin/env ruby
# frozen_string_literal: true
#
# add-swift-backend-config.rb — Phase 2 build-time backend toggle.
#
# Adds `Debug-Swift` / `Release-Swift` build configurations (clones of Debug /
# Release) that define `COLUMBA_BACKEND_SWIFT` + `ENABLE_NETWORK_EXTENSION` on the
# ColumbaApp target, plus a shared `Columba-Swift` scheme that builds them.
# Selecting that scheme (or `xcodebuild -scheme Columba-Swift`) builds the native
# reticulum-swift/LXMF-swift backend instead of the embedded-Python default and
# enables the background Network-Extension wiring; the rest of the app is backend-
# agnostic (BackendFactory's `#if COLUMBA_BACKEND_SWIFT`).
#
# Additive + idempotent — only adds the new configs/scheme, never strips packages
# or other settings (unlike the stale configure-xcodeproj.rb). Safe to re-run.
#
# Usage:  ruby support/add-swift-backend-config.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Columba.xcodeproj', __dir__)
APP_TARGET = 'ColumbaApp'
# Swift compilation conditions injected on the app target's -Swift configs.
# COLUMBA_BACKEND_SWIFT selects the native backend; ENABLE_NETWORK_EXTENSION
# compiles the background-NE wiring (TunnelManager/ExtensionFrameReader/etc.).
APP_CONDITIONS = %w[COLUMBA_BACKEND_SWIFT ENABLE_NETWORK_EXTENSION].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

# (base config name => Swift variant name)
VARIANTS = { 'Debug' => 'Debug-Swift', 'Release' => 'Release-Swift' }.freeze

def ensure_swift_config(owner, base_name, swift_name, project, conditions: [])
  list = owner.build_configuration_list
  cfg = list.build_configurations.find { |c| c.name == swift_name }

  if cfg.nil?
    base = list.build_configurations.find { |c| c.name == base_name }
    raise "no '#{base_name}' config on #{owner}" unless base

    cfg = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
    cfg.name = swift_name
    cfg.build_settings = base.build_settings.dup
    cfg.base_configuration_reference = base.base_configuration_reference
    list.build_configurations << cfg
    puts "  + #{swift_name} on #{owner.respond_to?(:name) ? owner.name : 'project'}"
  end

  # Idempotently ensure each Swift compilation condition — runs on first create
  # AND on every re-run, so adding a new condition (e.g. ENABLE_NETWORK_EXTENSION
  # alongside COLUMBA_BACKEND_SWIFT) only needs a re-run of this script. Token-
  # exact match (split), not substring, so conditions can't false-positive.
  return if conditions.empty?

  existing = cfg.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] || '$(inherited)'
  tokens = existing.split
  added = []
  conditions.each do |cond|
    next if tokens.include?(cond)
    tokens << cond
    added << cond
  end
  unless added.empty?
    cfg.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = tokens.join(' ')
    puts "    ~ #{swift_name} on #{owner.respond_to?(:name) ? owner.name : 'project'}: += #{added.join(' ')}"
  end
end

VARIANTS.each do |base_name, swift_name|
  # Project-level config (Xcode requires the config to exist at project + target).
  ensure_swift_config(project, base_name, swift_name, project)
  # Per-target — inject the app conditions only on the app target.
  project.targets.each do |target|
    conds = target.name == APP_TARGET ? APP_CONDITIONS : []
    ensure_swift_config(target, base_name, swift_name, project, conditions: conds)
  end
end

project.save
puts "Saved #{File.basename(PROJECT_PATH)}"

# Shared `Columba-Swift` scheme: clone the existing Columba scheme, retarget its
# actions at the -Swift configs.
schemes_dir = File.join(PROJECT_PATH, 'xcshareddata', 'xcschemes')
base_scheme_path = File.join(schemes_dir, 'Columba.xcscheme')
if File.exist?(base_scheme_path)
  scheme = Xcodeproj::XCScheme.new(base_scheme_path)
  scheme.launch_action.build_configuration  = 'Debug-Swift'
  scheme.test_action.build_configuration     = 'Debug-Swift'
  scheme.analyze_action.build_configuration  = 'Debug-Swift'
  scheme.profile_action.build_configuration  = 'Release-Swift'
  scheme.archive_action.build_configuration  = 'Release-Swift'
  scheme.save_as(PROJECT_PATH, 'Columba-Swift', true)
  puts 'Wrote Columba-Swift.xcscheme (shared)'
else
  warn "WARN: #{base_scheme_path} not found — skipped scheme creation"
end
