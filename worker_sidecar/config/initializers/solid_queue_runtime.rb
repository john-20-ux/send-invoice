# frozen_string_literal: true

heartbeat_interval = Integer(ENV.fetch("SEND_INVOICE_QUEUE_HEARTBEAT_INTERVAL_SECONDS", "10"), 10)
alive_threshold = Integer(ENV.fetch("SEND_INVOICE_QUEUE_ALIVE_THRESHOLD_SECONDS", "300"), 10)

SolidQueue.process_heartbeat_interval = heartbeat_interval.seconds
SolidQueue.process_alive_threshold = alive_threshold.seconds
