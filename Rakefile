# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "ruby_app/lib"
  task.pattern = "ruby_app/test/**/*_test.rb"
end

desc "Start the Send Invoice Ruby app"
task :server do
  ruby "app.rb"
end

task default: :test
