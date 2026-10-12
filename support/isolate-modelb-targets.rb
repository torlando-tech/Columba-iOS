#!/usr/bin/env ruby
# Compatibility entry point: there are no separate runtime flavor targets.
warn 'Use support/configure-unified-hosting.rb; both hosts ship in ColumbaApp.'
load File.expand_path('configure-unified-hosting.rb', __dir__)
