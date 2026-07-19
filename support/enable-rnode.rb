#!/usr/bin/env ruby
# frozen_string_literal: true

warn <<~MESSAGE
  support/enable-rnode.rb is retired because project-wide feature mutation can
  leak Model B-only behavior into the shipping Python product.
  Configure the explicit ColumbaModelBApp target through the Columba-ModelB
  scheme and reconcile target ownership with support/isolate-modelb-targets.rb.
MESSAGE
exit 1
