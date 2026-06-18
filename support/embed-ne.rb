#!/usr/bin/env ruby
# frozen_string_literal: true
#
# embed-ne.rb — wire ColumbaNetworkExtension into the app so a device build embeds
# the signed .appex into ColumbaApp.app/PlugIns (C2 packaging completion). Adds the
# app->NE target dependency + an "Embed App Extensions" copy-files phase (PlugIns,
# CodeSignOnCopy), and ensures the NE target carries the signing team. Idempotent.
#
# Usage:  ruby support/embed-ne.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Columba.xcodeproj', __dir__)
APP_NAME = 'ColumbaApp'
NE_NAME  = 'ColumbaNetworkExtension'
TEAM     = 'M2977H5PM5'

project = Xcodeproj::Project.open(PROJECT_PATH)
app = project.targets.find { |t| t.name == APP_NAME } or raise "no #{APP_NAME} target"
ne  = project.targets.find { |t| t.name == NE_NAME }  or raise "no #{NE_NAME} target"

# 1. Target dependency: app depends on the NE (so the NE builds before the embed).
if app.dependencies.any? { |d| d.target&.uuid == ne.uuid }
  puts "  = #{APP_NAME} already depends on #{NE_NAME}"
else
  app.add_dependency(ne)
  puts "  + #{APP_NAME} -> #{NE_NAME} target dependency"
end

# 2. Embed App Extensions copy-files phase (PlugIns), embedding the .appex with
#    code-sign-on-copy.
embed = app.copy_files_build_phases.find do |p|
  p.symbol_dst_subfolder_spec == :plug_ins || p.name == 'Embed App Extensions'
end
if embed.nil?
  embed = app.new_copy_files_build_phase('Embed App Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
  puts "  + Embed App Extensions phase"
else
  puts "  = Embed App Extensions phase present"
end

if embed.files.any? { |bf| bf.file_ref&.uuid == ne.product_reference.uuid }
  puts "  = #{NE_NAME}.appex already embedded"
else
  bf = embed.add_file_reference(ne.product_reference)
  bf.settings = { 'ATTRIBUTES' => %w[RemoveHeadersOnCopy CodeSignOnCopy] }
  puts "  + embed #{NE_NAME}.appex (CodeSignOnCopy)"
end

# 3. Ensure the NE target signs with the same team + automatic style.
ne.build_configurations.each do |c|
  c.build_settings['DEVELOPMENT_TEAM'] = TEAM if (c.build_settings['DEVELOPMENT_TEAM'] || '').empty?
  c.build_settings['CODE_SIGN_STYLE'] = 'Automatic' if (c.build_settings['CODE_SIGN_STYLE'] || '').empty?
end
puts "  ~ #{NE_NAME} DEVELOPMENT_TEAM/CODE_SIGN_STYLE ensured"

project.save
puts "Saved #{File.basename(PROJECT_PATH)}"
