#!/usr/bin/env ruby
# frozen_string_literal: true

# RETIRED: Debug-Swift, Release-Swift, and the Columba-Swift scheme encoded the
# obsolete assumption that a build configuration selected Model B.
abort <<~MESSAGE
  support/add-swift-backend-config.rb is retired and made no changes.
  Use the explicit ColumbaModelBApp target (COLUMBA_RUNTIME_MODEL_B) through the
  Columba-ModelB scheme. To repair the graph, run:
    ruby support/isolate-modelb-targets.rb
MESSAGE
