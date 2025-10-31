# frozen_string_literal: true

require "test_helper"
require "json"
require "cgi"
require "crush/utils/flows/gitlab/mr_reviewer"

class GitlabMrReviewerTest < Minitest::Test
  FakeClock = Struct.new(:time) do
    def now
      time
    end
  end

  class FakeGitRunner
    attr_reader :commands

    def initialize(diff: "diff --git")
      @diff = diff
      @commands = []
    end

    def clone(url, dir, redactions: {})
      @commands << [:clone, url, dir.to_s, redactions]
      FileUtils.mkdir_p(dir)
    end

    def fetch(dir, refspec, redactions: {})
      @commands << [:fetch, dir.to_s, refspec, redactions]
    end

    def diff(dir, base_ref, head_ref)
      @commands << [:diff, dir.to_s, base_ref, head_ref]
      @diff
    end
  end

  class FakeClient
    def initialize(project:, merge_request:, changes:)
      @project = project
      @merge_request = merge_request
      @changes = changes
    end

    def get(path, _params = {})
      case path
      when "/api/v4/projects/#{CGI.escape(@project.fetch("path_with_namespace"))}"
        @project
      when %r{/api/v4/projects/#{@project.fetch("id")}/merge_requests/\d+\z}
        @merge_request
      when %r{/api/v4/projects/#{@project.fetch("id")}/merge_requests/\d+/changes\z}
        @changes
      else
        raise "Unexpected path: #{path}"
      end
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_generates_review_artifacts
    mr_url = "https://gitlab.example.com/group/project/-/merge_requests/5"
    project = {
      "id" => 42,
      "name" => "Project",
      "path_with_namespace" => "group/project",
      "description" => "Sample",
      "web_url" => "https://gitlab.example.com/group/project",
      "http_url_to_repo" => "https://gitlab.example.com/group/project.git"
    }
    merge_request = {
      "iid" => 5,
      "title" => "Add feature",
      "description" => "Implements feature",
      "state" => "opened",
      "draft" => false,
      "source_branch" => "feature",
      "target_branch" => "main",
      "author" => { "name" => "Dev" },
      "web_url" => mr_url,
      "sha" => "abc123",
      "diff_refs" => { "base_sha" => "base", "head_sha" => "head" },
      "changes_count" => "2",
      "additions" => 10,
      "deletions" => 2,
      "merged_at" => nil,
      "created_at" => "2024-01-01T00:00:00Z",
      "updated_at" => "2024-01-02T00:00:00Z",
      "user_notes_count" => 1
    }
    changes = {
      "changes" => [
        {
          "old_path" => "app/models/user.rb",
          "new_path" => "app/models/user.rb",
          "diff" => "@@ -1 +1 @@"
        }
      ]
    }

    fake_client = FakeClient.new(project: project, merge_request: merge_request, changes: changes)
    fake_git = FakeGitRunner.new(diff: "diff --git a/file b/file")
    config = {
      gitlab_token: "token",
      crush_config: File.join(@tmpdir, "crush.json"),
      out_root: @tmpdir,
      git_executable: "git"
    }
    File.write(config[:crush_config], "{}")

    clock = FakeClock.new(Time.utc(2024, 1, 1, 12, 0, 0))
    flow = Crush::Utils::Flows::Gitlab::MrReviewer.new(
      argv: [mr_url],
      config: config,
      client_factory: ->(_url, _token, _per_page) { fake_client },
      git_runner: fake_git,
      clock: clock
    )

    crush_output = {
      command: ["crush"],
      stdout: "# Summary\nDetails",
      stderr: ""
    }

    capture_io do
      flow.stub(:run_crush, ->(*_args) { crush_output }) do
        flow.call
      end
    end

    review_dir = Pathname(@tmpdir).join("group-project", "mr-5")
    assert_path_exists review_dir

    markdown_path = review_dir.join("group-project-mr-5.md")
    assert_path_exists markdown_path
    assert_includes markdown_path.read, "# Summary"

    json_path = review_dir.join("group-project-mr-5.json")
    payload = JSON.parse(json_path.read)
    assert_equal mr_url, payload.dig("inputs", "merge_request_url")
    assert_equal markdown_path.to_s, payload.dig("outputs", "review_path")
    assert_equal crush_output[:stdout], payload.dig("outputs", "summary")

    diff_path = review_dir.join("group-project-mr-5.diff")
    assert_path_exists diff_path
    assert_includes diff_path.read, "diff --git"

    aggregate_path = review_dir.join("group-project-mr-5-aggregate.json")
    aggregate = JSON.parse(aggregate_path.read)
    assert_equal 1, aggregate.dig("stats", "changed_files")
    assert_equal "Add feature", aggregate.dig("merge_request", "title")

    raw_project = review_dir.join("raw", "project.json")
    assert_path_exists raw_project
    assert_equal project["id"], JSON.parse(raw_project.read).fetch("id")

    assert_equal [
      [
        :clone,
        "https://oauth2:token@gitlab.example.com/group/project.git",
        review_dir.join("repo").to_s,
        {
          "https://oauth2:token@gitlab.example.com/group/project.git" => "https://gitlab.example.com/group/project.git",
          "token" => "[REDACTED]"
        }
      ],
      [
        :fetch,
        review_dir.join("repo").to_s,
        "merge-requests/5/head:mr/5",
        {
          "https://oauth2:token@gitlab.example.com/group/project.git" => "https://gitlab.example.com/group/project.git",
          "token" => "[REDACTED]"
        }
      ],
      [:fetch, review_dir.join("repo").to_s, "main:mr/base-5", {}],
      [:diff, review_dir.join("repo").to_s, "mr/base-5", "mr/5"]
    ], fake_git.commands
  end
end
