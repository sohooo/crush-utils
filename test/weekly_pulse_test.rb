# frozen_string_literal: true

require "test_helper"
require "crush/utils/cli"
require "crush/utils/flows/pulse/weekly_pulse"
require "json"

class WeeklyPulseFlowTest < Minitest::Test
  WeeklyPulse = Crush::Utils::Flows::Pulse::WeeklyPulse

  FakeClock = Struct.new(:now)

  class FakeGitlabClient
    attr_reader :requests

    def initialize(window)
      @window = window
      @requests = []
    end

    def get(path, params = {}, headers = {})
      @requests << [:get, path, params, headers]
      raise "Unexpected params" unless params.empty? && headers.empty?
      raise "Unexpected path: #{path}" unless path == "/api/v4/groups/Engineering"

      { "id" => 321 }
    end

    def paginate(path, params = {})
      @requests << [:paginate, path, params]
      case path
      when "/api/v4/groups/321/projects"
        expect_params(params, include_subgroups: "true", with_shared: "true")
        [{ "id" => 99, "name" => "App" }]
      when "/api/v4/groups/321/issues"
        expect_params(
          params,
          updated_after: time_at_start,
          updated_before: time_at_end,
          scope: "all",
          state: "opened"
        )
        [{ "id" => 1, "title" => "Improve docs" }]
      when "/api/v4/groups/321/merge_requests"
        expect_params(
          params,
          updated_after: time_at_start,
          updated_before: time_at_end,
          scope: "all"
        )
        [{ "id" => 2, "title" => "Add feature", "merged_at" => "#{@window[:end]}T00:00:00Z" }]
      when "/api/v4/projects/99/repository/commits"
        expect_params(params, since: time_at_start, until: time_at_end)
        [{ "id" => "abc123", "author_name" => "Dev" }]
      when "/api/v4/projects/99/pipelines"
        expect_params(params, updated_after: time_at_start, updated_before: time_at_end)
        [
          { "id" => 10, "status" => "success" },
          { "id" => 11, "status" => "failed" }
        ]
      when "/api/v4/projects/99/events"
        expect_params(params, after: @window[:start], before: @window[:end])
        [{ "id" => 5, "action_name" => "pushed" }]
      else
        raise "Unexpected path: #{path}"
      end
    end

    private

    def time_at_start
      "#{@window[:start]}T00:00:00Z"
    end

    def time_at_end
      "#{@window[:end]}T00:00:00Z"
    end

    def expect_params(params, expected)
      params = params.transform_keys(&:to_s)
      expected.each do |key, value|
        actual = params[key.to_s]
        raise "Missing #{key} in #{params.inspect}" if actual.nil?
        raise "Expected #{key} to be #{value.inspect}, got #{actual.inspect}" unless actual == value
      end
      params
    end
  end

  def test_call_generates_reports_and_logs_without_external_requests
    Dir.mktmpdir do |tmp|
      tmp_path = Pathname(tmp)
      out_root = tmp_path.join("out")
      log_root = tmp_path.join("logs")
      crush_config = tmp_path.join("lead.crush.json")
      crush_config.write("{}")

      date = Date.new(2024, 1, 3)
      week_start = (date - ((date.wday + 6) % 7))
      window = { start: week_start.strftime("%F"), end: (week_start + 7).strftime("%F") }
      fake_client = FakeGitlabClient.new(window)

      status = Struct.new(:success?).new(true)
      captured_prompts = []

      Open3.stub(:capture3, lambda do |*command|
        assert_equal "crush", command.first
        captured_prompts << command.last
        ["Generated summary #{captured_prompts.length}", "", status]
      end) do
        Crush::Utils.stub(:log_dir, log_root) do
          WeeklyPulse::GitlabClient.stub(:new, ->(**_opts) { fake_client }) do
            flow = WeeklyPulse.new(
              argv: [],
              config: {
                gitlab_base: "https://gitlab.example.com",
                gitlab_token: "secret",
                groups: ["Engineering"],
                out_root: out_root,
                crush_config: crush_config,
                mattermost_webhook: nil,
                per_page: 50,
                date: date
              },
              clock: FakeClock.new(Time.utc(2024, 1, 4, 12, 0, 0))
            )

            WeeklyPulse.stub(:new, ->(**_args) { flow }) do
              capture_io { Crush::Utils::CLI.start(["pulse.weekly"]) }
            end
          end
        end
      end

      year_week = "2024_01"
      out_dir = out_root.join(year_week)
      group_dir = out_dir.join("engineering")
      assert_path_exists out_dir
      assert_path_exists group_dir

      summary = group_dir.join("summary.md").read
      assert_includes summary, "Generated summary 1"

      overall_summary = out_dir.join("overall_summary.md").read
      assert_includes overall_summary, "Generated summary 2"

      aggregate = JSON.parse(group_dir.join("group_aggregate.json").read)
      assert_equal "Engineering", aggregate["group"]
      assert_equal 1, aggregate.fetch("issues").length

      stats_dir = group_dir.join("stats")
      commit_stats = JSON.parse(stats_dir.join("commits.json").read)
      assert_equal 1, commit_stats.fetch("count")
      assert_equal "Dev", commit_stats.fetch("authors").first.fetch("name")

      log_path = Dir[log_root.join("pulse", "weekly", "*.json")].first
      refute_nil log_path
      log_payload = JSON.parse(File.read(log_path))
      assert_equal ["Engineering"], log_payload.dig("inputs", "groups")
      assert_equal 1, log_payload.dig("outputs", "groups").length
      assert_equal "Generated summary 2", log_payload.dig("outputs", "overall", "summary")

      assert_equal 2, captured_prompts.length
      assert captured_prompts.all? { |prompt| prompt.include?("Engineering") }
      assert_equal :get, fake_client.requests.first.first
      assert_equal 6, fake_client.requests.count { |entry| entry.first == :paginate }
    end
  end

  private

  def assert_path_exists(path)
    assert path.exist?, "Expected #{path} to exist"
  end
end
