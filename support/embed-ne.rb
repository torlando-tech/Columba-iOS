#!/usr/bin/env ruby
# frozen_string_literal: true

# Compatibility entry point. Extension dependency/embed ownership is part of
# the complete target matrix and must not be maintained by a second mutator.
# The authoritative reconciler attaches ColumbaNetworkExtension only to
# ColumbaModelBApp and asserts that ColumbaApp has no dependency or embed.
reconciler = File.expand_path('isolate-modelb-targets.rb', __dir__)
warn 'embed-ne.rb delegates to explicit ColumbaModelBApp reconciliation; ColumbaApp is never an extension host.'
load reconciler
