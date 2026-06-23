# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("ruby_app/lib", __dir__))

require "send_invoice/boot"

SendInvoice::Boot.start if $PROGRAM_NAME == __FILE__
