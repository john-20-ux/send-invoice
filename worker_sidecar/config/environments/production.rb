# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = true
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }
end
