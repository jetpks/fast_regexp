# frozen_string_literal: true

require "bundler/gem_tasks"

require "rake/extensiontask"

Rake::ExtensionTask.new("fast_regexp") do |c|
  c.lib_dir = "lib/fast_regexp"
end

require "rspec/core/rake_task"
RSpec::Core::RakeTask.new(:spec)
