# frozen_string_literal: true

require "zlib"

class ApplicationJob < ActiveJob::Base
  private

  def resolve_unstarted_async_request(runtime:, request_id:, prepared:, phase:)
    return prepared if prepared["started"]
    return prepared unless request_id

    message = prepared["message"].to_s

    if retryable_async_start_message?(message)
      request = runtime.store.async_job_request(request_id)
      attempts = request ? request["attempts"].to_i : 1
      delay = retry_delay_seconds_for_attempt(attempts, request_id: request_id)
      runtime.store.requeue_async_job_request(
        request_id,
        error_message: message,
        available_at: (Time.now.utc + delay).iso8601
      )
      warn "[send-invoice-worker] async request #{request_id} requeued after #{delay}s during #{phase}: #{message}"
    else
      failure_message = message.empty? ? "Async request could not be started" : message
      runtime.store.fail_async_job_request(request_id, failure_message)
      warn "[send-invoice-worker] async request #{request_id} failed during #{phase}: #{failure_message}"
    end

    prepared
  end

  def async_request_max_attempts
    integer_env("ASYNC_REQUEST_MAX_ATTEMPTS", 5)
  end

  def async_request_retry_base_seconds
    integer_env("ASYNC_REQUEST_RETRY_BASE_SECONDS", 5)
  end

  def async_request_retry_max_seconds
    integer_env("ASYNC_REQUEST_RETRY_MAX_SECONDS", 300)
  end

  def async_request_retry_jitter_seconds
    integer_env("ASYNC_REQUEST_RETRY_JITTER_SECONDS", 3)
  end

  def deterministic_retry_jitter_seconds(request_id, attempt_number)
    max_jitter = async_request_retry_jitter_seconds
    return 0 if max_jitter <= 0
    return 0 if request_id.to_s.empty?

    Zlib.crc32("#{request_id}:#{attempt_number}") % (max_jitter + 1)
  end

  def retry_delay_seconds_for_attempt(attempt_number, request_id: nil)
    exponent = [attempt_number.to_i - 1, 0].max
    delay = async_request_retry_base_seconds * (2**exponent)
    delay += deterministic_retry_jitter_seconds(request_id, attempt_number)
    [delay, async_request_retry_max_seconds].min
  end

  def handle_async_request_failure(runtime:, request_id:, error:, phase:)
    return unless request_id

    request = runtime.store.async_job_request(request_id)
    unless request
      warn "[send-invoice-worker] async request #{request_id} missing during #{phase} failure handling: #{error.class}: #{error.message}"
      return
    end

    attempts = request["attempts"].to_i
    max_attempts = async_request_max_attempts

    if attempts < max_attempts
      delay = retry_delay_seconds_for_attempt(attempts, request_id: request_id)
      runtime.store.requeue_async_job_request(
        request_id,
        error_message: error.message,
        available_at: (Time.now.utc + delay).iso8601
      )
      warn "[send-invoice-worker] async request #{request_id} retry scheduled after #{delay}s (attempt #{attempts}/#{max_attempts}) during #{phase}: #{error.class}: #{error.message}"
    else
      runtime.store.fail_async_job_request(request_id, error.message)
      warn "[send-invoice-worker] async request #{request_id} failed permanently after #{attempts} attempt(s) during #{phase}: #{error.class}: #{error.message}"
    end
  end

  def integer_env(key, fallback)
    Integer(ENV.fetch(key, fallback.to_s), 10)
  rescue ArgumentError
    fallback
  end

  def retryable_async_start_message?(message)
    return false if message.to_s.empty?

    message.include?("already in progress") || message.start_with?("Rate limited.")
  end
end
