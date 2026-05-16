# frozen_string_literal: true

require "bundler/gem_tasks"
require "rb_sys/extensiontask"

GEMSPEC = Gem::Specification.load("fast_regexp.gemspec")

# rb_sys/extensiontask wraps rake-compiler with cross-compilation tasks.
# CI (oxidize-rb/cross-gem-action) sets RUBY_TARGET to drive cross builds;
# locally, `rake compile` and `rake build` do the host build.
RbSys::ExtensionTask.new("fast_regexp", GEMSPEC) do |ext|
  ext.lib_dir = "lib/fast_regexp"
end

require "rspec/core/rake_task"
RSpec::Core::RakeTask.new(:spec)
