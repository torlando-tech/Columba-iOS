#!/usr/bin/env ruby
# Enable COLUMBA_NOMADNET_ENABLED in the Release / Release-Swift project
# configs, mirroring Debug / Debug-Swift. Idempotent.
#
# NomadNet browsing was originally gated to Debug only (project-level
# SWIFT_ACTIVE_COMPILATION_CONDITIONS carried the flag in Debug/Debug-Swift but
# not in the Release configs, which had no conditions line at all). Both
# backends now implement fetchNomadNetPage, so there is no reason to keep it
# out of Release.

require 'xcodeproj'

PROJECT = File.expand_path('../Columba.xcodeproj', __dir__)
FLAG    = 'COLUMBA_NOMADNET_ENABLED'

project = Xcodeproj::Project.open(PROJECT)

%w[Release Release-Swift].each do |cfg_name|
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

  # Flag first, then $(inherited) — matches the Debug blocks' ordering.
  rest = tokens.reject { |t| t == FLAG }
  rest << '$(inherited)' unless rest.include?('$(inherited)')
  cfg.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
    ([FLAG] + rest).join(' ')
  puts "#{cfg_name}: set SWIFT_ACTIVE_COMPILATION_CONDITIONS = #{cfg.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'].inspect}"
end

project.save
puts 'saved.'
