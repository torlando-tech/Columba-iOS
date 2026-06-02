#!/usr/bin/env ruby
# frozen_string_literal: true
#
# add-ne-backend-deps.rb — Track C2(e): link the native Swift RNS + LXMF stack
# into the ColumbaNetworkExtension target so the NE can run the backend itself
# (Model B / Track A5). Idempotent + additive: adds ReticulumSwift + LXMFSwift as
# package product dependencies + Frameworks-phase entries on the NE target only,
# attaching to the SAME XCRemoteSwiftPackageReference the app target already uses.
#
# Usage:  ruby support/add-ne-backend-deps.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Columba.xcodeproj', __dir__)
NE_TARGET = 'ColumbaNetworkExtension'
PRODUCTS = %w[ReticulumSwift LXMFSwift].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
ne = project.targets.find { |t| t.name == NE_TARGET }
raise "no #{NE_TARGET} target" unless ne

existing = ne.package_product_dependencies.map(&:product_name)

PRODUCTS.each do |product|
  if existing.include?(product)
    puts "  = #{product} already linked on #{NE_TARGET}"
    next
  end

  # Reuse the XCRemoteSwiftPackageReference another target already resolves for
  # this product (the app target links both), so the NE attaches to the same
  # pinned package rather than introducing a second resolution.
  ref_dep = project.targets.flat_map(&:package_product_dependencies)
                   .find { |d| d.product_name == product }
  raise "no existing package product dependency for #{product} to source the package ref" unless ref_dep

  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = ref_dep.package
  dep.product_name = product
  ne.package_product_dependencies << dep

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  ne.frameworks_build_phase.files << build_file

  puts "  + #{product} linked on #{NE_TARGET}"
end

project.save
puts "Saved #{File.basename(PROJECT_PATH)}"
