#!/usr/bin/env ruby
# Enable COLUMBA_MIGRATION_ENABLED across project build configs. Idempotent.
#
# The data-migration feature (encrypted .columba export/import: identities,
# conversations, messages, interfaces, settings — MigrationExporter/Importer/
# Crypto + MigrationScreen + onboarding restore) was gated behind
# COLUMBA_MIGRATION_ENABLED, which was set in NO build config and had in fact
# never been compiled — so Settings → Data Migration fell through to the #else
# branch and rendered "Data migration unavailable in this build".
#
# Default targets the Debug configs only (feature is device-unverified — kept
# out of Release until an export→import round-trip is validated). Pass
# `--configs=Debug,Release,Debug-Swift,Release-Swift` to widen. Configs that do
# not exist in the current project (e.g. the -Swift configs, which are added by
# add-swift-backend-config.rb at generation time) are skipped with a warning
# rather than aborting.

require 'xcodeproj'

PROJECT = File.expand_path('../Columba.xcodeproj', __dir__)
FLAG    = 'COLUMBA_MIGRATION_ENABLED'

arg = ARGV.find { |a| a.start_with?('--configs=') }
names = arg ? arg.split('=', 2).last.split(',') : %w[Debug Debug-Swift]

project = Xcodeproj::Project.open(PROJECT)

names.each do |cfg_name|
  cfg = project.build_configurations.find { |c| c.name == cfg_name }
  unless cfg
    puts "#{cfg_name}: config not found — skipping"
    next
  end

  conds = cfg.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']
  tokens =
    case conds
    when nil   then ['$(inherited)']
    when Array then conds.dup
    else conds.split(/\s+/)
    end

  if tokens.include?(FLAG)
    puts "#{cfg_name}: already has #{FLAG} — no change"
    next
  end

  inherited = tokens.delete('$(inherited)')
  tokens << FLAG
  tokens << '$(inherited)' if inherited
  cfg.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = tokens.join(' ')
  puts "#{cfg_name}: set = #{cfg.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'].inspect}"
end

project.save
puts 'saved.'
