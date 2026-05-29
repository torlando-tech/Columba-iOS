#!/usr/bin/env ruby
# Enable COLUMBA_RNODE_ENABLED across project build configs. Idempotent.
#
# The RNode (LoRa) interface wizard was gated behind COLUMBA_RNODE_ENABLED,
# which was set in NO build config and had in fact never been compiled — so the
# interface-type picker offered "RNode" while its wizard was compiled out:
# selecting it dismissed the sheet and presented nothing (a silent dead-end).
#
# Default targets the Debug configs only (device-unverified hardware feature —
# kept out of Release until verified on real RNode hardware). Pass
# `--configs=Debug,Release,Debug-Swift,Release-Swift` to widen.

require 'xcodeproj'

PROJECT = File.expand_path('../Columba.xcodeproj', __dir__)
FLAG    = 'COLUMBA_RNODE_ENABLED'

arg = ARGV.find { |a| a.start_with?('--configs=') }
names = arg ? arg.split('=', 2).last.split(',') : %w[Debug Debug-Swift]

project = Xcodeproj::Project.open(PROJECT)

names.each do |cfg_name|
  cfg = project.build_configurations.find { |c| c.name == cfg_name }
  raise "project config #{cfg_name.inspect} not found" unless cfg

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
