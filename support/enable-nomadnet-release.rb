#!/usr/bin/env ruby
# frozen_string_literal: true

warn <<~MESSAGE
  support/enable-nomadnet-release.rb is retired because legacy configuration
  variants are no longer part of the Columba project.
  Configure the explicit ColumbaModelBApp target through the Columba-ModelB
  scheme and reconcile target ownership with support/isolate-modelb-targets.rb.
MESSAGE
exit 1
