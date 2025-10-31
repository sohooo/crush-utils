# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "date"
require "fileutils"
require "time"
require "open3"
require "pathname"
require "erb"

module Crush
  module Utils
    module Flows
      module Pulse
        class WeeklyPulse
          FLOW_NAME = "pulse.weekly"

          class TemplateContext
            def initialize(locals = {})
              locals.each do |key, value|
                define_singleton_method(key) { value }
              end
            end

            def get_binding
              binding
            end
          end

          def self.register!
            Crush::Utils::Flows.register(FLOW_NAME, self)
          end

          def initialize(argv: [], config: nil, clock: Time)
            @argv = argv
            @config = config
            @clock = clock
          end

          def call
            cfg = configuration
            date = cfg[:date]
            window_start, window_end = week_window(date)
            window = {
              start: window_start.strftime("%F"),
              end: window_end.strftime("%F")
            }

            year_week = iso_week(date)
            cfg[:out_dir] = cfg[:out_root].join(year_week)
            ensure_directories(cfg[:out_dir])

            puts "▶ Weekly window: #{window[:start]} .. #{window[:end]}  →  #{cfg[:out_dir]}"
            puts "▶ Groups: #{cfg[:groups].join(" ")}"

            client = Crush::Utils::GitlabClient.new(base_url: cfg[:gitlab_base], token: cfg[:gitlab_token], per_page: cfg[:per_page])

            group_results = cfg[:groups].map do |group|
              fetch_group_activity(group, cfg, client, window)
            end

            overall = overall_summary(group_results, window, cfg)

            timestamp = @clock.now.utc.strftime("%Y-%m-%d_%H%M%S")
            flow_log_dir = Crush::Utils.log_dir.join("pulse", "weekly")
            inputs = {
              "gitlab_base" => cfg[:gitlab_base],
              "groups" => cfg[:groups],
              "window" => window,
              "per_page" => cfg[:per_page],
              "out_dir" => cfg[:out_dir].to_s,
              "crush_config" => cfg[:crush_config].to_s,
              "mattermost_webhook_configured" => !cfg[:mattermost_webhook].to_s.empty?
            }
            outputs = {
              "groups" => group_results.map do |result|
                {
                  "group" => result[:group],
                  "aggregate_path" => result[:aggregate_path].to_s,
                  "summary_path" => result[:summary_path].to_s,
                  "summary" => result[:summary],
                  "crush_command" => result[:crush_command]
                }
              end,
              "overall" => {
                "aggregate_path" => overall[:aggregate_path].to_s,
                "summary_path" => overall[:summary_path].to_s,
                "summary" => overall[:summary],
                "crush_command" => overall[:crush_command],
                "mattermost_response_code" => overall[:mattermost_response_code]
              }
            }
            log_path = log_results(flow_log_dir, timestamp, inputs, outputs)
            puts "✓ Logged run: #{log_path}"
          end

          private

          attr_reader :argv

          def configuration
            @configuration ||= begin
              cfg = @config || default_config
              cfg[:out_root] = Pathname(cfg[:out_root]).expand_path
              cfg[:crush_config] = Pathname(cfg[:crush_config]).expand_path
              cfg[:date] = cfg[:date].is_a?(Date) ? cfg[:date] : Date.parse(cfg[:date].to_s)
              cfg
            end
          end

          def default_config
            load_env_if_needed

            gitlab_base = (ENV["GITLAB_BASE"] || "https://gitlab.example.com").sub(%r{/+$}, "")
            gitlab_token = ENV["GITLAB_TOKEN"]
            raise "Set GITLAB_TOKEN via the environment or .env file" if gitlab_token.nil? || gitlab_token.empty?

            groups = (ENV["GROUPS"] || "dbsys").split(",").map(&:strip).reject(&:empty?)

            {
              gitlab_base: gitlab_base,
              gitlab_token: gitlab_token,
              groups: groups,
              out_root: Crush::Utils.root.join("reports", "pulse"),
              crush_config: script_dir.join(".crush", "lead.crush.json"),
              mattermost_webhook: ENV["MATTERMOST_WEBHOOK"],
              per_page: (ENV["PER_PAGE"] || "100").to_i,
              date: Date.today
            }
          end

          def script_dir
            @script_dir ||= Pathname(__dir__).expand_path
          end

          def repo_root
            Crush::Utils.root
          end

          def load_env_if_needed
            needs_env = %w[GITLAB_BASE GITLAB_TOKEN GROUPS MATTERMOST_WEBHOOK].any? do |key|
              ENV[key].nil? || ENV[key].empty?
            end
            return unless needs_env

            env_path = repo_root.join(".env")
            return unless env_path.file?

            env_path.readlines(chomp: true).each do |line|
              next if line.strip.empty? || line.lstrip.start_with?("#")

              key, value = line.split("=", 2)
              next unless key

              value = (value || "").strip
              value = value.gsub(/^['"]|['"]$/, "")
              ENV[key] = value if ENV[key].nil? || ENV[key].empty?
            end
          end

          def render_template(name, locals = {})
            template_path = script_dir.join("templates", "#{name}.erb")
            template = ERB.new(template_path.read, trim_mode: "-")
            context = TemplateContext.new(locals)
            template.result(context.get_binding)
          end

          def slugify(value)
            value.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
          end

          def escape_path_segment(segment)
            URI.encode_www_form_component(segment)
          end

          def iso_week(date)
            format("%<year>d_%<week>02d", year: date.cwyear, week: date.cweek)
          end

          def week_window(date)
            days_from_monday = (date.wday + 6) % 7
            week_start = date - days_from_monday
            week_end = week_start + 7
            [week_start, week_end]
          end

          def ensure_directories(*paths)
            paths.each do |path|
              Pathname(path).mkpath
            end
          end

          def write_json(path, data)
            Pathname(path).write(JSON.pretty_generate(data))
          end

          def generate_group_stats(group_dir, commits_all, pipelines_all, issues, merge_requests)
            stats_dir = group_dir.join("stats")
            ensure_directories(stats_dir)

            commit_stats = {
              "count" => commits_all.length,
              "authors" => commits_all.group_by { |c| c["author_name"] }.map do |name, commits|
                { "name" => name, "commits" => commits.length }
              end.sort_by { |entry| -entry["commits"] }
            }
            pipeline_stats = {
              "count" => pipelines_all.length,
              "merged" => pipelines_all.count { |p| p["status"] == "success" },
              "failed" => pipelines_all.count { |p| p["status"] == "failed" }
            }
            issues_stats = { "open_or_updated" => issues.length }
            mr_stats = {
              "updated" => merge_requests.length,
              "merged" => merge_requests.count { |mr| !mr["merged_at"].nil? }
            }

            write_json(stats_dir.join("commits.json"), commit_stats)
            write_json(stats_dir.join("pipelines.json"), pipeline_stats)
            write_json(stats_dir.join("issues.json"), issues_stats)
            write_json(stats_dir.join("mrs.json"), mr_stats)
          end

          def run_crush(prompt, crush_config)
            command = ["crush", "--config", crush_config.to_s, "--yolo", "-c", prompt]
            stdout, stderr, status = Open3.capture3(*command)
            raise "Crush command failed: #{stderr}" unless status.success?

            { command: command, stdout: stdout, stderr: stderr }
          end

          def fetch_group_activity(group, config, client, window)
            gslug = slugify(group)
            group_dir = config[:out_dir].join(gslug)
            raw_dir = group_dir.join("raw")
            ensure_directories(raw_dir)

            puts "→ Fetching group '#{group}'"
            group_json = client.get("/api/v4/groups/#{escape_path_segment(group)}")
            gid = group_json.fetch("id")

            projects = client.paginate("/api/v4/groups/#{gid}/projects", include_subgroups: "true", with_shared: "true")
            issues = client.paginate(
              "/api/v4/groups/#{gid}/issues",
              updated_after: "#{window[:start]}T00:00:00Z",
              updated_before: "#{window[:end]}T00:00:00Z",
              scope: "all",
              state: "opened"
            )
            merge_requests = client.paginate(
              "/api/v4/groups/#{gid}/merge_requests",
              updated_after: "#{window[:start]}T00:00:00Z",
              updated_before: "#{window[:end]}T00:00:00Z",
              scope: "all"
            )

            write_json(raw_dir.join("projects.json"), projects)
            write_json(raw_dir.join("issues.json"), issues)
            write_json(raw_dir.join("mrs.json"), merge_requests)

            commits_all = []
            pipelines_all = []
            events_all = []

            projects.each do |project|
              pid = project["id"]
              commits = client.paginate(
                "/api/v4/projects/#{pid}/repository/commits",
                since: "#{window[:start]}T00:00:00Z",
                until: "#{window[:end]}T00:00:00Z"
              )
              pipelines = client.paginate(
                "/api/v4/projects/#{pid}/pipelines",
                updated_after: "#{window[:start]}T00:00:00Z",
                updated_before: "#{window[:end]}T00:00:00Z"
              )
              events = client.paginate(
                "/api/v4/projects/#{pid}/events",
                after: window[:start],
                before: window[:end]
              )

              commits_all.concat(commits)
              pipelines_all.concat(pipelines)
              events_all.concat(events)

              write_json(raw_dir.join("#{pid}-commits.json"), commits)
              write_json(raw_dir.join("#{pid}-pipelines.json"), pipelines)
              write_json(raw_dir.join("#{pid}-events.json"), events)
            end

            write_json(raw_dir.join("commits.all.json"), commits_all)
            write_json(raw_dir.join("pipelines.all.json"), pipelines_all)
            write_json(raw_dir.join("events.all.json"), events_all)

            generate_group_stats(group_dir, commits_all, pipelines_all, issues, merge_requests)

            group_aggregate = {
              "group" => group,
              "window" => { "since" => window[:start], "until" => window[:end] },
              "projects" => projects,
              "issues" => issues,
              "merge_requests" => merge_requests,
              "commits" => commits_all,
              "pipelines" => pipelines_all,
              "events" => events_all
            }

            aggregate_path = group_dir.join("group_aggregate.json")
            write_json(aggregate_path, group_aggregate)

            prompt = render_template(
              "group_summary",
              aggregate_path: aggregate_path.to_s,
              group: group,
              window: window
            )

            crush_result = run_crush(prompt, config[:crush_config])
            summary_path = group_dir.join("summary.md")
            summary_path.write(crush_result[:stdout])
            puts "✓ Group summary: #{summary_path}"

            {
              group: group,
              slug: gslug,
              aggregate_path: aggregate_path,
              aggregate: group_aggregate,
              summary_path: summary_path,
              summary: crush_result[:stdout],
              crush_command: crush_result[:command],
              crush_stderr: crush_result[:stderr]
            }
          end

          def overall_summary(group_results, window, config)
            overall_json = {
              "window" => { "since" => window[:start], "until" => window[:end] },
              "groups" => group_results.map { |result| result[:aggregate] }
            }
            overall_json_path = config[:out_dir].join("overall_aggregate.json")
            write_json(overall_json_path, overall_json)

            prompt = render_template(
              "overall_summary",
              aggregate_path: overall_json_path.to_s,
              window: window,
              groups: group_results.map { |result| { name: result[:group], slug: result[:slug] } }
            )

            crush_result = run_crush(prompt, config[:crush_config])
            overall_md_path = config[:out_dir].join("overall_summary.md")
            overall_md_path.write(crush_result[:stdout])
            puts "✓ Overall summary: #{overall_md_path}"

            mattermost_status = nil
            if config[:mattermost_webhook] && !config[:mattermost_webhook].empty?
              uri = URI.parse(config[:mattermost_webhook])
              payload = { text: crush_result[:stdout] }.to_json
              request = Net::HTTP::Post.new(uri)
              request["Content-Type"] = "application/json"
              request.body = payload
              Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
                response = http.request(request)
                mattermost_status = response.code
                unless response.is_a?(Net::HTTPSuccess)
                  raise "Mattermost webhook failed: #{response.code} #{response.body}"
                end
              end
              puts "✓ Posted to Mattermost"
            end

            {
              aggregate_path: overall_json_path,
              summary_path: overall_md_path,
              summary: crush_result[:stdout],
              crush_command: crush_result[:command],
              crush_stderr: crush_result[:stderr],
              mattermost_response_code: mattermost_status
            }
          end

          def log_results(flow_log_dir, timestamp, inputs, outputs)
            ensure_directories(flow_log_dir)
            log_path = flow_log_dir.join("#{timestamp}.json")
            log_path.write(
              JSON.pretty_generate(
                {
                  "timestamp" => timestamp,
                  "inputs" => inputs,
                  "outputs" => outputs
                }
              )
            )
            log_path
          end

        end
      end
    end
  end
end

Crush::Utils::Flows::Pulse::WeeklyPulse.register!
