# frozen_string_literal: true

require "test_helper"
require "json"
require "fileutils"
require "crush/utils/gitlab_mcp"

class GitlabMcpMrReviewerToolTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @review_path = Pathname(@tmpdir).join("review.md")
    @review_path.write("# Summary\nReview body")
    @results_path = Pathname(@tmpdir).join("results.json")
    results_payload = {
      "inputs" => { "merge_request_url" => "https://gitlab.example.com/group/project/-/merge_requests/1" },
      "outputs" => {
        "summary" => "# Summary\nReview body",
        "crush_command" => ["crush"]
      }
    }
    @results_path.write(JSON.dump(results_payload))
    @aggregate_path = Pathname(@tmpdir).join("aggregate.json")
    @aggregate_path.write(JSON.dump({ "merge_request" => { "title" => "Add feature" } }))
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_mr_reviewer_tool_runs_flow_and_returns_structured_content
    merge_request_url = "https://gitlab.example.com/group/project/-/merge_requests/1"
    captured_args = nil
    review_path = @review_path
    results_path = @results_path
    aggregate_path = @aggregate_path

    fake_flow_class = Class.new do
      attr_reader :argv, :config, :client_factory, :git_runner, :clock

      define_method(:initialize) do |argv:, config:, client_factory:, git_runner:, clock:|
        @argv = argv
        @config = config
        @client_factory = client_factory
        @git_runner = git_runner
        @clock = clock
      end

      define_method(:call) do
        {
          review_path: review_path,
          results_path: results_path,
          aggregate_path: aggregate_path
        }
      end
    end

    factory = lambda do |argv:, config:, client_factory:, git_runner:, clock:|
      captured_args = { argv: argv, config: config, client_factory: client_factory, git_runner: git_runner, clock: clock }
      fake_flow_class.new(argv:, config:, client_factory:, git_runner:, clock: clock)
    end

    clock = Struct.new(:now).new(Time.utc(2024, 1, 1))

    response = Crush::Utils::GitlabMCP::Tools::MrReviewer.call(
      merge_request_url: merge_request_url,
      config: { "gitlab_token" => "token" },
      server_context: {
        mr_reviewer_factory: factory,
        client_factory: :client_factory,
        git_runner: :git_runner,
        clock: clock
      }
    )

    refute_nil captured_args
    assert_equal [merge_request_url], captured_args[:argv]
    assert_equal({ gitlab_token: "token" }, captured_args[:config])
    assert_equal :client_factory, captured_args[:client_factory]
    assert_equal :git_runner, captured_args[:git_runner]
    assert_equal clock, captured_args[:clock]

    content = response.content
    assert_equal 1, content.length
    assert_includes content.first[:text], "GitLab merge request review"
    assert_includes content.first[:text], "Review body"

    structured = response.structured_content
    assert_equal "gitlab.mr_reviewer", structured[:flow]
    assert_equal merge_request_url, structured[:merge_request_url]
    assert_equal review_path.to_s, structured[:review_path]
    assert_equal results_path.to_s, structured[:results_path]
    assert_equal aggregate_path.to_s, structured[:aggregate_path]
    assert_equal "# Summary\nReview body", structured[:outputs]["summary"]
    assert_equal "Add feature", structured[:aggregate].dig("merge_request", "title")
  end
end

class GitlabMcpWeeklyPulseToolTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @out_root = Pathname(@tmpdir).join("pulse")
    @out_dir = @out_root.join("2024_01")
    @group_dir = @out_dir.join("engineering")
    FileUtils.mkdir_p(@group_dir)

    @group_dir.join("summary.md").write("Group summary")
    @group_dir.join("group_aggregate.json").write(JSON.dump({ "group" => "Engineering" }))
    @out_dir.join("overall_summary.md").tap do |path|
      path.dirname.mkpath
      path.write("Overall summary")
    end
    @out_dir.join("overall_aggregate.json").write(JSON.dump({ "window" => { "since" => "2024-01-01" }, "groups" => [] }))
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_weekly_pulse_tool_surfaces_summary_paths
    captured_config = nil
    out_dir = @out_dir

    fake_flow_class = Class.new do
      attr_reader :config

      define_method(:initialize) do |argv:, config:, clock:|
        @config = config.dup
      end

      define_method(:call) do
        @config[:out_dir] = out_dir
        nil
      end

      define_method(:configuration) do
        @config
      end
    end

    factory = lambda do |argv:, config:, clock:|
      captured_config = config
      fake_flow_class.new(argv:, config:, clock: clock)
    end

    crush_config = @out_root.join("config.json")
    crush_config.dirname.mkpath
    crush_config.write("{}")

    response = Crush::Utils::GitlabMCP::Tools::WeeklyPulse.call(
      config: {
        "gitlab_base" => "https://gitlab.example.com",
        "gitlab_token" => "secret",
        "groups" => ["Engineering"],
        "out_root" => @out_root.to_s,
        "crush_config" => crush_config.to_s,
        "per_page" => 50,
        "date" => "2024-01-03"
      },
      server_context: {
        weekly_pulse_factory: factory,
        clock: Struct.new(:now).new(Time.utc(2024, 1, 5))
      }
    )

    refute_nil captured_config
    assert_equal "https://gitlab.example.com", captured_config[:gitlab_base]
    assert_equal ["Engineering"], captured_config[:groups]
    assert_equal 50, captured_config[:per_page]
    assert_equal "2024-01-03", captured_config[:date]

    content = response.content
    assert_equal 1, content.length
    assert_includes content.first[:text], "Weekly pulse summaries generated"
    assert_includes content.first[:text], "Overall summary"

    structured = response.structured_content
    assert_equal "pulse.weekly", structured[:flow]
    assert_equal out_dir.to_s, structured[:out_dir]
    assert_equal 1, structured[:groups].length
    group_payload = structured[:groups].first
    assert_equal "Engineering", group_payload[:name]
    assert_equal "engineering", group_payload[:slug]
    assert_equal @group_dir.join("summary.md").to_s, group_payload[:summary_path]
    assert_equal "Group summary", group_payload[:summary]
    assert_equal "Engineering", group_payload[:aggregate]["group"]

    overall_payload = structured[:overall]
    assert_equal @out_dir.join("overall_summary.md").to_s, overall_payload[:summary_path]
    assert_equal "Overall summary", overall_payload[:summary]
    assert_equal "2024-01-01", overall_payload[:aggregate].dig("window", "since")
  end
end

class GitlabMcpServerTest < Minitest::Test
  def test_server_registers_gitlab_tools
    server = Crush::Utils::GitlabMCP::Server.new

    response = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json)
    payload = JSON.parse(response)
    tool_names = payload.dig("result", "tools").map { |tool| tool["name"] }

    assert_includes tool_names, "gitlab.mr_reviewer"
    assert_includes tool_names, "pulse.weekly"
  end
end
