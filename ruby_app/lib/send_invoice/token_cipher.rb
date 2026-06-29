# frozen_string_literal: true

require "openssl"
require "base64"

module SendInvoice
  # Encrypts sensitive values (Shopify access/refresh tokens) at rest using
  # AES-256-GCM. Ciphertext is tagged with a version prefix so we can tell it
  # apart from legacy plaintext and migrate transparently on the next write.
  #
  # The key comes from ENV["ENCRYPTION_KEY"] and may be either:
  #   * 64 hex chars  (32 bytes), or
  #   * base64 of 32 bytes, or
  #   * any string (hashed to 32 bytes via SHA-256 as a fallback).
  #
  # When no key is configured (e.g. local mock mode) the cipher is a no-op
  # passthrough so the app still runs; production must set ENCRYPTION_KEY.
  class TokenCipher
    PREFIX = "enc:v1:"
    CIPHER = "aes-256-gcm"
    IV_LEN = 12
    TAG_LEN = 16

    def initialize(key)
      @key = derive_key(key)
    end

    def enabled?
      !@key.nil?
    end

    # Returns versioned ciphertext, or the original value unchanged when no key
    # is configured / the value is blank or already encrypted.
    def encrypt(plaintext)
      return plaintext if plaintext.nil? || plaintext.to_s.empty?
      return plaintext unless enabled?
      return plaintext if encrypted?(plaintext)

      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.encrypt
      cipher.key = @key
      iv = cipher.random_iv
      cipher.iv = iv
      ciphertext = cipher.update(plaintext.to_s) + cipher.final
      payload = iv + cipher.auth_tag + ciphertext
      PREFIX + Base64.strict_encode64(payload)
    end

    # Returns plaintext. Legacy (unprefixed) values pass through unchanged so we
    # can read tokens stored before encryption was enabled.
    def decrypt(value)
      return value if value.nil? || value.to_s.empty?
      return value unless encrypted?(value)
      return value unless enabled?

      payload = Base64.strict_decode64(value.to_s[PREFIX.length..])
      iv = payload[0, IV_LEN]
      tag = payload[IV_LEN, TAG_LEN]
      ciphertext = payload[(IV_LEN + TAG_LEN)..]

      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.decrypt
      cipher.key = @key
      cipher.iv = iv
      cipher.auth_tag = tag
      cipher.update(ciphertext) + cipher.final
    rescue OpenSSL::Cipher::CipherError, ArgumentError
      # Corrupt/garbled ciphertext — surface as nil rather than crash callers.
      nil
    end

    def encrypted?(value)
      value.to_s.start_with?(PREFIX)
    end

    private

    def derive_key(key)
      raw = key.to_s.strip
      return nil if raw.empty?

      if raw.match?(/\A[0-9a-fA-F]{64}\z/)
        [raw].pack("H*")
      else
        begin
          decoded = Base64.strict_decode64(raw)
          return decoded if decoded.bytesize == 32
        rescue ArgumentError
          # fall through to hashing
        end
        OpenSSL::Digest::SHA256.digest(raw)
      end
    end
  end
end
