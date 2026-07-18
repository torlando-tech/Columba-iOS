#!/usr/bin/env ruby
# frozen_string_literal: true

warn <<~MESSAGE
  support/enable-migration.rb is retired because project-wide feature mutation
  is incompatible with compile-time runtime isolation.
  Configure the explicit ColumbaModelBApp target through the Columba-ModelB
  scheme and reconcile target ownership with support/isolate-modelb-targets.rb.
MESSAGE
exit 1
