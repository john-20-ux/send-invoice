# frozen_string_literal: true

require_relative "test_helper"

class ApplicationJobTest < Minitest::Test
  class ProbeJob < ApplicationJob
    public :handle_async_request_failure
    public :deterministic_retry_jitter_seconds
    public :resolve_unstarted_async_request
    public :retry_delay_seconds_for_attempt
  end

  class FakeStore
    attr_reader :requeued_request, :failed_request

    def initialize(request)
      @request = request
    end

    def async_job_request(_request_id)
      @request
    end

    def requeue_async_job_request(request_id, error_message:, available_at:)
      @requeued_request = {
        request_id: request_id,
        error_message: error_message,
        available_at: available_at
      }
    end

    def fail_async_job_request(request_id, error_message)
      @failed_request = {
        request_id: request_id,
        error_message: error_message
      }
    end
  end

  class FakeRuntime
    attr_reader :store

    def initialize(store)
      @store = store
    end
  end

  def setup
    @job = ProbeJob.new
  end

  def with_env(values)
    previous = {}
    values.each do |key, value|
      previous[key] = ENV[key]
      ENV[key] = value
    end

    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def test_requeues_failed_request_with_exponential_backoff
    request_id = "request-1"
    store = FakeStore.new({ "id" => request_id, "attempts" => 2 })
    runtime = FakeRuntime.new(store)

    with_env(
      "ASYNC_REQUEST_MAX_ATTEMPTS" => "5",
      "ASYNC_REQUEST_RETRY_BASE_SECONDS" => "3",
      "ASYNC_REQUEST_RETRY_MAX_SECONDS" => "20",
      "ASYNC_REQUEST_RETRY_JITTER_SECONDS" => "2"
    ) do
      before = Time.now.utc
      @job.handle_async_request_failure(
        runtime: runtime,
        request_id: request_id,
        error: StandardError.new("boom"),
        phase: "dispatch"
      )

      scheduled_at = Time.iso8601(store.requeued_request[:available_at])
      expected_delay = @job.retry_delay_seconds_for_attempt(2, request_id: request_id)
      assert_in_delta((before + expected_delay).to_f, scheduled_at.to_f, 1.0)
    end

    assert_nil store.failed_request
    refute_nil store.requeued_request
    assert_equal request_id, store.requeued_request[:request_id]
    assert_equal "boom", store.requeued_request[:error_message]
  end

  def test_caps_retry_delay_at_maximum
    with_env(
      "ASYNC_REQUEST_RETRY_BASE_SECONDS" => "5",
      "ASYNC_REQUEST_RETRY_MAX_SECONDS" => "12",
      "ASYNC_REQUEST_RETRY_JITTER_SECONDS" => "3"
    ) do
      assert_equal 12, @job.retry_delay_seconds_for_attempt(4, request_id: "request-cap")
    end
  end

  def test_retry_jitter_is_deterministic_per_request_and_attempt
    with_env("ASYNC_REQUEST_RETRY_JITTER_SECONDS" => "4") do
      first = @job.deterministic_retry_jitter_seconds("request-1", 2)
      second = @job.deterministic_retry_jitter_seconds("request-1", 2)
      third = @job.deterministic_retry_jitter_seconds("request-2", 2)

      assert_equal first, second
      assert_operator first, :>=, 0
      assert_operator first, :<=, 4
      assert_operator third, :>=, 0
      assert_operator third, :<=, 4
    end
  end

  def test_marks_request_failed_after_max_attempts
    request_id = "request-2"
    store = FakeStore.new({ "id" => request_id, "attempts" => 3 })
    runtime = FakeRuntime.new(store)

    with_env("ASYNC_REQUEST_MAX_ATTEMPTS" => "3") do
      @job.handle_async_request_failure(
        runtime: runtime,
        request_id: request_id,
        error: StandardError.new("still broken"),
        phase: "run_sync_command"
      )
    end

    assert_nil store.requeued_request
    refute_nil store.failed_request
    assert_equal request_id, store.failed_request[:request_id]
    assert_equal "still broken", store.failed_request[:error_message]
  end

  def test_resolve_unstarted_async_request_requeues_retryable_contention
    request_id = "request-3"
    store = FakeStore.new({ "id" => request_id, "attempts" => 1 })
    runtime = FakeRuntime.new(store)
    prepared = { "started" => false, "message" => "Sync already in progress" }

    with_env(
      "ASYNC_REQUEST_RETRY_BASE_SECONDS" => "4",
      "ASYNC_REQUEST_RETRY_MAX_SECONDS" => "20",
      "ASYNC_REQUEST_RETRY_JITTER_SECONDS" => "0"
    ) do
      before = Time.now.utc
      result = @job.resolve_unstarted_async_request(
        runtime: runtime,
        request_id: request_id,
        prepared: prepared,
        phase: "run_sync"
      )

      assert_equal prepared, result
      scheduled_at = Time.iso8601(store.requeued_request[:available_at])
      assert_in_delta((before + 4).to_f, scheduled_at.to_f, 1.0)
    end

    assert_nil store.failed_request
    assert_equal request_id, store.requeued_request[:request_id]
  end

  def test_resolve_unstarted_async_request_fails_permanent_start_error
    request_id = "request-4"
    store = FakeStore.new({ "id" => request_id, "attempts" => 1 })
    runtime = FakeRuntime.new(store)
    prepared = { "started" => false, "message" => "Missing Shopify access token" }

    result = @job.resolve_unstarted_async_request(
      runtime: runtime,
      request_id: request_id,
      prepared: prepared,
      phase: "run_sync"
    )

    assert_equal prepared, result
    assert_nil store.requeued_request
    assert_equal request_id, store.failed_request[:request_id]
    assert_equal "Missing Shopify access token", store.failed_request[:error_message]
  end
end
