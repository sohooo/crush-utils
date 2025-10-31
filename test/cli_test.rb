# frozen_string_literal: true

require "test_helper"
require "crush/utils/cli"

class CLITest < Minitest::Test
  def test_runs_registered_flow
    argv = ["pulse.weekly"]
    calls = []
    result = { ok: true }

    Crush::Utils::Flows.stub(:run, lambda do |name, argv:|
      calls << [name, argv]
      result
    end) do
      assert_equal result, Crush::Utils::CLI.start(argv.dup)
    end

    assert_equal [["pulse.weekly", []]], calls
  end

  def test_requires_flow_name
    out, err = capture_io do
      assert_raises(SystemExit) { Crush::Utils::CLI.start([]) }
    end

    assert_equal "", out
    assert_includes err, "No flow name provided."
  end

  def test_invalid_option_prints_usage
    out, err = capture_io do
      assert_raises(SystemExit) { Crush::Utils::CLI.start(["--unknown"]) }
    end

    assert_equal "", out
    assert_includes err, "invalid option: --unknown"
    assert_includes err, "Usage: crush-utils"
  end
end
