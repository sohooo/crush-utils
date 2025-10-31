# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"

require "bundler/setup"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

require "crush/utils"
require "crush/utils/flows"

module TestHelpers
  def with_env(vars)
    original = {}
    vars.each do |key, value|
      original[key] = ENV.key?(key) ? ENV[key] : :__missing__
      ENV[key] = value
    end
    yield
  ensure
    vars.each_key do |key|
      previous = original.fetch(key)
      if previous == :__missing__
        ENV.delete(key)
      else
        ENV[key] = previous
      end
    end
  end
end

Minitest::Test.include(TestHelpers)
