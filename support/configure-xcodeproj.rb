#!/usr/bin/env ruby
# frozen_string_literal: true

# RETIRED: the Python bootstrap predates explicit shipping and Model B targets.
# Its former implementation mutated ColumbaApp directly and removed shared
# package references, so retaining it as an executable repair path is unsafe.
abort <<~MESSAGE
  support/configure-xcodeproj.rb is retired and made no changes.
  ColumbaApp is the Python shipping target; ColumbaModelBApp is the explicit
  COLUMBA_RUNTIME_MODEL_B target built by the Columba-ModelB scheme.
  Run: ruby support/isolate-modelb-targets.rb
MESSAGE
