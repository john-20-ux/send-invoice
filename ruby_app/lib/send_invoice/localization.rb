# frozen_string_literal: true

require "i18n"
require "i18n/backend/fallbacks"

module SendInvoice
  # Thin wrapper around ruby-i18n: loads locale YAML, tracks which locales are
  # available, and resolves a request's preferred language to one of them.
  module Localization
    AVAILABLE_LOCALES = %i[en es ta].freeze
    DEFAULT_LOCALE = :en

    class << self
      def setup!(locales_glob)
        return if @configured

        I18n::Backend::Simple.include(I18n::Backend::Fallbacks)
        I18n.load_path |= Dir[locales_glob]
        I18n.available_locales = AVAILABLE_LOCALES
        I18n.default_locale = DEFAULT_LOCALE
        I18n.enforce_available_locales = true
        I18n.fallbacks = I18n::Locale::Fallbacks.new(DEFAULT_LOCALE)
        I18n.backend.load_translations
        @configured = true
      end

      # Return the first candidate (query param, header, …) that maps to an
      # available locale, else the default. Handles "es-ES", "ta_IN", etc.
      def resolve(*candidates)
        candidates.flatten.compact.each do |candidate|
          code = candidate.to_s.strip.downcase[/[a-z]+/].to_s
          next if code.empty?

          sym = code.to_sym
          return sym if AVAILABLE_LOCALES.include?(sym)
        end
        DEFAULT_LOCALE
      end
    end
  end
end
