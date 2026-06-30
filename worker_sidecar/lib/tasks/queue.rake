# frozen_string_literal: true

namespace :queue do
  desc "Load the Solid Queue schema only if its tables are missing (deploy-safe)"
  task ensure_schema: :environment do
    if SolidQueue::Job.connection.table_exists?("solid_queue_jobs")
      puts "[queue] solid_queue tables already present; skipping schema load"
    else
      puts "[queue] loading Solid Queue schema"
      Rake::Task["db:schema:load:queue"].invoke
    end
  end
end
