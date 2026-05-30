#!/usr/bin/env ruby
# Generate a deterministic module/target-level Mermaid graph for Columba-iOS.
#
# Merges two dependency systems into one diagram:
#   - pbxproj targets + their target-to-target and SPM-product deps
#     (parsed via the xcodeproj Ruby gem, same gem used by configure-xcodeproj.rb)
#   - Internal Package.swift target-to-target deps
#     (parsed via `swift package dump-package`)
#
# Writes a Mermaid `flowchart TD` block into ARCHITECTURE.md between the
# <!-- module-graph-start --> and <!-- module-graph-end --> markers.
#
# Regen: ruby support/generate-module-graph.rb

require 'xcodeproj'
require 'json'
require 'open3'
require 'set'

REPO_ROOT    = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(REPO_ROOT, 'Columba.xcodeproj')
ARCH_MD_PATH = File.join(REPO_ROOT, 'ARCHITECTURE.md')
START_MARKER = '<!-- module-graph-start -->'
END_MARKER   = '<!-- module-graph-end -->'

nodes = {}            # name => { label:, kind: }
edges = Set.new       # of "src --> dst" strings

def pbxproj_kind(target)
  case target.product_type
  when 'com.apple.product-type.application'     then :app
  when /app-extension/                          then :extension
  when 'com.apple.product-type.framework',
       'com.apple.product-type.framework.static' then :bridge
  else :bridge
  end
end

def spm_kind(name)
  %w[COpus CCodec2].include?(name) ? :c_lib : :spm_lib
end

# ──────── pbxproj side ────────
project = Xcodeproj::Project.open(PROJECT_PATH)

project.targets.each do |t|
  # Skip test bundles — noise that doesn't belong in an architecture overview.
  next if t.product_type&.include?('bundle.unit-test')
  next if t.product_type&.include?('bundle.ui-testing')

  nodes[t.name] ||= { label: t.name, kind: pbxproj_kind(t) }

  # target → target deps (pbxproj-level)
  t.dependencies.each do |dep|
    dst = dep.target&.name
    next unless dst
    nodes[dst] ||= { label: dst, kind: :bridge }
    edges << "#{t.name} --> #{dst}"
  end

  # target → SPM product deps
  t.package_product_dependencies.each do |pp|
    name = pp.product_name
    nodes[name] ||= { label: name, kind: spm_kind(name) }
    edges << "#{t.name} --> #{name}"
  end
end

# ──────── SPM side (Package.swift internal target deps) ────────
stdout, status = Open3.capture2('swift', 'package', 'dump-package', '--package-path', REPO_ROOT)
abort "swift package dump-package failed" unless status.success?
manifest = JSON.parse(stdout)

manifest['targets'].each do |target|
  name = target['name']
  nodes[name] ||= { label: name, kind: spm_kind(name) }
  Array(target['dependencies']).each do |dep|
    # Shapes: {"byName":[<name>,null]} | {"target":[<name>,null]} | {"product":[<name>,<pkg>,null,null]}
    dst =
      if    dep['byName']  then dep['byName'].first
      elsif dep['target']  then dep['target'].first
      elsif dep['product'] then dep['product'].first
      end
    next unless dst
    nodes[dst] ||= { label: dst, kind: spm_kind(dst) }
    edges << "#{name} --> #{dst}"
  end
end

# ──────── Render Mermaid ────────
CLASS_STYLES = {
  app:       'classDef app       fill:#1f6feb,stroke:#0d419d,color:#fff',
  extension: 'classDef extension fill:#8957e5,stroke:#553098,color:#fff',
  bridge:    'classDef bridge    fill:#f0883e,stroke:#9e4c0f,color:#fff',
  spm_lib:   'classDef spm_lib   fill:#3fb950,stroke:#0f7a2e,color:#fff',
  c_lib:     'classDef c_lib     fill:#6e7681,stroke:#30363d,color:#fff',
}.freeze

lines = ['```mermaid', 'flowchart TD']
nodes.keys.sort.each { |id| lines << "    #{id}[\"#{nodes[id][:label]}\"]" }
edges.sort.each { |e| lines << "    #{e}" }
CLASS_STYLES.each_value { |s| lines << "    #{s}" }
nodes.group_by { |_, m| m[:kind] }.each do |kind, members|
  ids = members.map(&:first).sort.join(',')
  lines << "    class #{ids} #{kind}" unless ids.empty?
end
lines << '```'
block = lines.join("\n")

# ──────── Inject between markers ────────
md = File.read(ARCH_MD_PATH)
abort "Markers not found in #{ARCH_MD_PATH}" unless md.include?(START_MARKER) && md.include?(END_MARKER)

# Anchor to start-of-line so inline-backtick mentions of the markers in the
# explanatory prose above don't match — only the bare marker pair does.
new_md = md.sub(
  /^#{Regexp.escape(START_MARKER)}\n.*?^#{Regexp.escape(END_MARKER)}$/m,
  "#{START_MARKER}\n#{block}\n#{END_MARKER}"
)
abort "Marker block not matched in #{ARCH_MD_PATH}" if new_md == md
File.write(ARCH_MD_PATH, new_md)

puts "Wrote module graph: #{nodes.size} nodes, #{edges.size} edges → #{ARCH_MD_PATH}"
