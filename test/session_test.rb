# frozen_string_literal: true

require "test_helper"
require "crush/utils/session"

class SessionTest < Minitest::Test
  FakeClock = Struct.new(:time) do
    def now
      time
    end
  end

  def test_persist_writes_structured_payload
    Dir.mktmpdir do |tmp|
      root = Pathname(tmp).join("logs")
      clock = FakeClock.new(Time.utc(2024, 1, 1, 12, 0, 0))
      session = Crush::Utils::Session.new(flow_name: "demo.flow", clock: clock, root_dir: root)

      path = session.persist!(
        inputs: { "input" => "value" },
        outputs: { "output" => 1 },
        metadata: { "note" => "example" }
      )

      assert path.file?, "expected #{path} to be written"
      data = JSON.parse(path.read)
      assert_equal "demo.flow", data.fetch("flow")
      assert_equal "2024-01-01T12:00:00Z", data.fetch("timestamp")
      assert_equal "value", data.dig("inputs", "input")
      assert_equal 1, data.dig("outputs", "output")
      assert_equal "example", data.dig("metadata", "note")
      assert_includes path.to_s, "demo.flow"
    end
  end
end
