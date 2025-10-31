# frozen_string_literal: true

require "cgi"
require "erb"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "time"
require "uri"

module Crush
  module Utils
    module Flows
      module Gitlab
        class MrReviewer
          FLOW_NAME = "gitlab.mr_reviewer"

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

          class GitRunner
            def initialize(executable: "git")
              @executable = executable
            end

            def clone(url, dir, redactions: {})
              run(["clone", "--origin", "origin", "--quiet", url, dir.to_s], redactions: redactions)
            end

            def fetch(dir, refspec, redactions: {})
              run(["-C", dir.to_s, "fetch", "origin", refspec], redactions: redactions)
            end

            def diff(dir, base_ref, head_ref)
              run(["-C", dir.to_s, "diff", base_ref, head_ref], capture: true)
            end

            private

            attr_reader :executable

            def run(args, capture: false, redactions: {})
              command = [executable, *args]
              stdout, stderr, status = Open3.capture3(*command)
              if status.success?
                return stdout if capture

                return nil
              end

              sanitized_command = redact(command.join(" "), redactions)
              sanitized_stderr = redact(stderr, redactions)
              raise Crush::Utils::Error, "Git command failed (#{sanitized_command}): #{sanitized_stderr.strip}"
            end

            def redact(text, redactions)
              redactions.reduce(text) do |memo, (pattern, replacement)|
                next memo unless pattern

                memo.gsub(pattern, replacement)
              end
            end
          end

          def self.register!
            Crush::Utils::Flows.register(FLOW_NAME, self)
          end

          def initialize(argv: [], config: nil, client_factory: nil, git_runner: nil, clock: Time)
            @argv = argv
            @config = config
            @client_factory = client_factory
            @git_runner = git_runner
            @clock = clock
          end

          def call
            mr_url = argv.first
            raise ArgumentError, "Provide a GitLab merge request URL" if mr_url.nil? || mr_url.strip.empty?

            parsed = parse_mr_url(mr_url)
            cfg = configuration(parsed[:base_url])
            git_runner = @git_runner || GitRunner.new(executable: cfg[:git_executable])

            review_root = cfg[:out_root].join(parsed[:project_slug], "mr-#{parsed[:iid]}")
            raw_dir = review_root.join("raw")
            ensure_directories(review_root, raw_dir)

            client = build_client(parsed[:base_url], cfg)

            project = client.get("/api/v4/projects/#{escape_project_path(parsed[:project_path])}")
            project_id = project.fetch("id")
            merge_request = client.get("/api/v4/projects/#{project_id}/merge_requests/#{parsed[:iid]}")
            changes = client.get("/api/v4/projects/#{project_id}/merge_requests/#{parsed[:iid]}/changes")

            write_json(raw_dir.join("project.json"), project)
            write_json(raw_dir.join("merge_request.json"), merge_request)
            write_json(raw_dir.join("changes.json"), changes)

            repo_dir = review_root.join("repo")
            ensure_clean_directory(repo_dir)

            clone_url = project.fetch("http_url_to_repo")
            token = cfg[:gitlab_token]
            auth_url = authenticated_clone_url(clone_url, token)
            redactions = {}
            redactions[auth_url] = clone_url if auth_url != clone_url
            redactions[token] = "[REDACTED]" if token && !token.empty?

            git_runner.clone(auth_url, repo_dir, redactions: redactions)

            mr_branch = "mr/#{parsed[:iid]}"
            git_runner.fetch(repo_dir, "merge-requests/#{parsed[:iid]}/head:#{mr_branch}", redactions: redactions)

            target_branch = (merge_request["target_branch"] || "main").to_s
            base_branch = "mr/base-#{parsed[:iid]}"
            git_runner.fetch(repo_dir, "#{target_branch}:#{base_branch}")

            diff_text = git_runner.diff(repo_dir, base_branch, mr_branch) || ""
            diff_path = review_root.join("#{parsed[:project_slug]}-mr-#{parsed[:iid]}.diff")
            diff_path.write(diff_text)

            aggregate_path = review_root.join("#{parsed[:project_slug]}-mr-#{parsed[:iid]}-aggregate.json")
            aggregate = build_aggregate(project, merge_request, changes, diff_path, parsed)
            write_json(aggregate_path, aggregate)

            prompt = render_template(
              "review_prompt",
              aggregate_path: aggregate_path.to_s,
              diff_path: diff_path.to_s,
              merge_request_url: merge_request["web_url"] || mr_url,
              project_path: project["path_with_namespace"] || parsed[:project_path]
            )

            crush_result = run_crush(prompt, cfg[:crush_config])

            review_path = review_root.join("#{parsed[:project_slug]}-mr-#{parsed[:iid]}.md")
            review_path.write(crush_result[:stdout])

            results_path = review_root.join("#{parsed[:project_slug]}-mr-#{parsed[:iid]}.json")
            inputs = {
              "merge_request_url" => mr_url,
              "project_path" => parsed[:project_path],
              "project_id" => project_id,
              "target_branch" => merge_request["target_branch"],
              "source_branch" => merge_request["source_branch"],
              "token_present" => !token.to_s.empty?,
              "review_directory" => review_root.to_s
            }
            outputs = {
              "aggregate_path" => aggregate_path.to_s,
              "diff_path" => diff_path.to_s,
              "review_path" => review_path.to_s,
              "summary" => crush_result[:stdout],
              "crush_command" => crush_result[:command]
            }
            write_json(results_path, {
              "timestamp" => clock.now.utc.iso8601,
              "inputs" => inputs,
              "outputs" => outputs
            })

            puts "✓ Review saved to #{review_path}"
            puts "✓ Inputs/outputs saved to #{results_path}"

            {
              review_path: review_path,
              results_path: results_path,
              aggregate_path: aggregate_path
            }
          end

          private

          attr_reader :argv, :clock

          def configuration(base_url)
            cfg = (@config || default_config(base_url)).dup
            cfg[:out_root] = Pathname(cfg[:out_root]).expand_path
            cfg[:crush_config] = Pathname(cfg[:crush_config]).expand_path
            cfg[:gitlab_token] = cfg[:gitlab_token].to_s
            cfg[:per_page] = (cfg[:per_page] || 100).to_i
            git_exec = cfg[:git_executable].to_s
            cfg[:git_executable] = git_exec.empty? ? "git" : git_exec
            cfg[:gitlab_base] = base_url
            cfg
          end

          def default_config(base_url)
            load_env_if_needed
            token = ENV["GITLAB_TOKEN"]
            raise "Set GITLAB_TOKEN via the environment or .env file" if token.nil? || token.empty?

            {
              gitlab_token: token,
              crush_config: script_dir.join(".crush", "mr_reviewer.crush.json"),
              out_root: Crush::Utils.root.join("reports", "gitlab", "mr_reviews"),
              per_page: (ENV["PER_PAGE"] || "100").to_i,
              git_executable: ENV["GIT_EXECUTABLE"] || "git",
              gitlab_base: base_url
            }
          end

          def build_client(base_url, cfg)
            factory = @client_factory || lambda do |url, token, per_page|
              Crush::Utils::GitlabClient.new(base_url: url, token: token, per_page: per_page)
            end
            factory.call(base_url, cfg[:gitlab_token], cfg[:per_page])
          end

          def parse_mr_url(url)
            uri = URI.parse(url)
            raise ArgumentError, "Invalid MR URL" unless uri.scheme && uri.host

            path = uri.path
            marker = "/-/merge_requests/"
            unless path.include?(marker)
              raise ArgumentError, "Invalid MR URL"
            end

            project_path, iid_part = path.split(marker, 2)
            project_path = project_path.sub(%r{^/}, "")
            iid = iid_part.to_s.split("/", 2).first
            raise ArgumentError, "Invalid MR URL" if project_path.empty? || iid.to_s.empty?

            base_url = "#{uri.scheme}://#{uri.host}"
            base_url += ":#{uri.port}" if uri.port && ![80, 443].include?(uri.port)

            {
              base_url: base_url,
              project_path: project_path,
              project_slug: slugify(project_path),
              iid: iid,
              mr_url: url
            }
          rescue URI::InvalidURIError
            raise ArgumentError, "Invalid MR URL"
          end

          def escape_project_path(path)
            CGI.escape(path)
          end

          def slugify(value)
            slug = value.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
            return slug unless slug.empty?

            value.tr("/", "-")
          end

          def authenticated_clone_url(url, token)
            return url if token.to_s.empty?

            uri = URI.parse(url)
            credentials = "oauth2:#{token}"
            uri.userinfo = credentials
            uri.to_s
          rescue URI::InvalidURIError
            url
          end

          def build_aggregate(project, merge_request, changes, diff_path, parsed)
            change_entries = Array(changes["changes"])
            {
              "generated_at" => clock.now.utc.iso8601,
              "project" => {
                "id" => project["id"],
                "name" => project["name"],
                "path_with_namespace" => project["path_with_namespace"],
                "description" => project["description"],
                "web_url" => project["web_url"]
              },
              "merge_request" => {
                "iid" => merge_request["iid"],
                "title" => merge_request["title"],
                "description" => merge_request["description"],
                "state" => merge_request["state"],
                "draft" => merge_request["draft"],
                "source_branch" => merge_request["source_branch"],
                "target_branch" => merge_request["target_branch"],
                "author" => merge_request.dig("author", "name"),
                "web_url" => merge_request["web_url"],
                "sha" => merge_request["sha"],
                "diff_refs" => merge_request["diff_refs"],
                "changes_count" => merge_request["changes_count"],
                "additions" => merge_request["additions"],
                "deletions" => merge_request["deletions"],
                "merged_at" => merge_request["merged_at"],
                "created_at" => merge_request["created_at"],
                "updated_at" => merge_request["updated_at"],
                "user_notes_count" => merge_request["user_notes_count"]
              },
              "stats" => {
                "changed_files" => change_entries.size,
                "additions" => merge_request["additions"],
                "deletions" => merge_request["deletions"],
                "changes_count" => merge_request["changes_count"]
              },
              "changes" => change_entries,
              "diff_path" => diff_path.to_s,
              "mr_url" => merge_request["web_url"] || parsed[:mr_url]
            }
          end

          def ensure_directories(*paths)
            paths.each { |path| Pathname(path).mkpath }
          end

          def ensure_clean_directory(path)
            Pathname(path).rmtree if Pathname(path).exist?
            Pathname(path).mkpath
          end

          def render_template(name, locals = {})
            template_path = script_dir.join("templates", "#{name}.erb")
            template = ERB.new(template_path.read, trim_mode: "-")
            context = TemplateContext.new(locals)
            template.result(context.get_binding)
          end

          def script_dir
            @script_dir ||= Pathname(__dir__).expand_path
          end

          def write_json(path, data)
            Pathname(path).write(JSON.pretty_generate(data))
          end

          def run_crush(prompt, crush_config)
            command = ["crush", "--config", crush_config.to_s, "--yolo", "-c", prompt]
            stdout, stderr, status = Open3.capture3(*command)
            raise "Crush command failed: #{stderr}" unless status.success?

            { command: command, stdout: stdout, stderr: stderr }
          end

          def load_env_if_needed
            keys = ["GITLAB_TOKEN"]
            needs_env = keys.any? { |key| ENV[key].nil? || ENV[key].empty? }
            return unless needs_env

            env_path = Crush::Utils.root.join(".env")
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
        end
      end
    end
  end
end

Crush::Utils::Flows::Gitlab::MrReviewer.register!
