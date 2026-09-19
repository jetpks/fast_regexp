# frozen_string_literal: true

require "fast_regexp"
require "tmpdir"
require "fileutils"

# CI runs the suite a second time with GC_STRESS set: a GC at every
# allocation, to catch a native object read after it was freed or moved.
GC.stress = true if %w[1 true yes].include?(ENV["GC_STRESS"].to_s.downcase)

RSpec.configure do |config|
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = "tmp/rspec_status.txt"

  config.filter_run focus: true
  config.run_all_when_everything_filtered = true

  # disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!
end
