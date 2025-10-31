#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'date'
require 'fileutils'
require 'time'
require 'open3'
require 'pathname'
require 'erb'

module Pulse
  module_function

  def script_dir
    @script_dir ||= Pathname.new(__dir__).expand_path
  end

  def repo_root
    @repo_root ||= script_dir.join('..', '..').expand_path
  end

  def load_env_if_needed
    needs_env = %w[GITLAB_BASE GITLAB_TOKEN GROUPS MATTERMOST_WEBHOOK].any? do |key|
      ENV[key].nil? || ENV[key].empty?
    end
    return unless needs_env

    env_path = repo_root.join('.env')
    return unless env_path.file?

    env_path.readlines(chomp: true).each do |line|
      next if line.strip.empty? || line.lstrip.start_with?('#')

      key, value = line.split('=', 2)
      next unless key

      value = (value || '').strip
      value = value.gsub(/^['"]|['"]$/, '')
      ENV[key] = value if ENV[key].nil? || ENV[key].empty?
    end
  end

  def config
    load_env_if_needed

    gitlab_base = (ENV['GITLAB_BASE'] || 'https://gitlab.example.com').sub(%r{/+$}, '')
    gitlab_token = ENV['GITLAB_TOKEN']
    raise 'Set GITLAB_TOKEN via the environment or .env file' if gitlab_token.nil? || gitlab_token.empty?

    groups = (ENV['GROUPS'] || 'dbsys').split(/\s+/).reject(&:empty?)

    {
      gitlab_base: gitlab_base,
      gitlab_token: gitlab_token,
      groups: groups,
      out_root: Pathname.new(ENV['OUT_ROOT'] || script_dir.join('reports').to_s).expand_path,
      crush_config: Pathname.new(ENV['CRUSH_CONFIG'] || script_dir.join('.crush', 'lead.crush.json').to_s).expand_path,
      mattermost_webhook: ENV['MATTERMOST_WEBHOOK'],
      per_page: (ENV['PER_PAGE'] || '100').to_i,
      date: Date.today
    }
  end

  class GitlabClient
    Response = Struct.new(:data, :raw_response)

    def initialize(base_url:, token:, per_page:)
      @base_url = base_url.sub(%r{/+$}, '')
      @token = token
      @per_page = per_page
    end

    def request(method, path, params: {}, headers: {}, body: nil)
      uri = build_uri(path, params)
      http_request = build_request(method, uri, headers, body)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        response = http.request(http_request)
        verify_response!(response)
        Response.new(parse_json(response.body, response['Content-Type']), response)
      end
    end

    def get(path, params = {}, headers = {})
      request(:get, path, params: params, headers: headers).data
    end

    def paginate(path, params = {})
      results = []
      page = 1
      loop do
        page_params = params.merge(page: page, per_page: @per_page)
        response = request(:get, path, params: page_params)
        data = response.data
        if data.is_a?(Array)
          results.concat(data)
        elsif data.nil?
          # nothing to add
        else
          results << data
        end
        next_page = response.raw_response['X-Next-Page']
        break if next_page.nil? || next_page.empty?

        page = next_page.to_i
        page = 1 if page <= 0
      end
      results
    end

    private

    def build_request(method, uri, headers, body)
      request_class = case method.to_s.downcase
                      when 'get' then Net::HTTP::Get
                      when 'post' then Net::HTTP::Post
                      when 'put' then Net::HTTP::Put
                      when 'delete' then Net::HTTP::Delete
                      when 'patch' then Net::HTTP::Patch
                      else
                        raise ArgumentError, "Unsupported HTTP method: #{method}"
                      end
      request = request_class.new(uri)
      request['PRIVATE-TOKEN'] = @token
      headers.each { |key, value| request[key] = value }
      request.body = body if body
      request
    end

    def build_uri(path, params = {})
      uri = URI.parse("#{@base_url}#{path}")
      query_params = []
      query_params.concat(URI.decode_www_form(uri.query)) if uri.query
      params.each do |key, value|
        query_params << [key.to_s, value]
      end
      uri.query = URI.encode_www_form(query_params) unless query_params.empty?
      uri
    end

    def verify_response!(response)
      return if response.is_a?(Net::HTTPSuccess)

      raise "GitLab request failed: #{response.code} #{response.body}"
    end

    def parse_json(body, content_type)
      return nil if body.nil? || body.empty?
      return body unless content_type&.include?('application/json')

      JSON.parse(body)
    rescue JSON::ParserError
      raise "Failed to parse JSON response: #{body.inspect}"
    end
  end

  class TemplateContext
    def initialize(locals = {})
      locals.each do |key, value|
        define_singleton_method(key) { value }
      end
    end

    def binding
      super
    end
  end

  def render_template(name, locals = {})
    template_path = script_dir.join('templates', "#{name}.erb")
    template = ERB.new(template_path.read, trim_mode: '-')
    template.result(TemplateContext.new(locals).binding)
  end

  def slugify(value)
    value.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')
  end

  def escape_path_segment(segment)
    URI.encode_www_form_component(segment)
  end

  def iso_week(date)
    format('%<year>d_%<week>02d', year: date.cwyear, week: date.cweek)
  end

  def week_window(date)
    days_from_monday = (date.wday + 6) % 7
    week_start = date - days_from_monday
    week_end = week_start + 7
    [week_start, week_end]
  end

  def ensure_directories(*paths)
    paths.each do |path|
      Pathname.new(path).mkpath
    end
  end

  def write_json(path, data)
    Pathname.new(path).write(JSON.pretty_generate(data))
  end

  def generate_group_stats(group_dir, commits_all, pipelines_all, issues, merge_requests)
    stats_dir = group_dir.join('stats')
    ensure_directories(stats_dir)

    commit_stats = {
      'count' => commits_all.length,
      'authors' => commits_all.group_by { |c| c['author_name'] }.map do |name, commits|
        { 'name' => name, 'commits' => commits.length }
      end.sort_by { |entry| -entry['commits'] }
    }
    pipeline_stats = {
      'count' => pipelines_all.length,
      'merged' => pipelines_all.count { |p| p['status'] == 'success' },
      'failed' => pipelines_all.count { |p| p['status'] == 'failed' }
    }
    issues_stats = { 'open_or_updated' => issues.length }
    mr_stats = {
      'updated' => merge_requests.length,
      'merged' => merge_requests.count { |mr| !mr['merged_at'].nil? }
    }

    write_json(stats_dir.join('commits.json'), commit_stats)
    write_json(stats_dir.join('pipelines.json'), pipeline_stats)
    write_json(stats_dir.join('issues.json'), issues_stats)
    write_json(stats_dir.join('mrs.json'), mr_stats)
  end

  def run_crush(prompt, crush_config)
    command = ['crush', '--config', crush_config.to_s, '--yolo', '-c', prompt]
    stdout, stderr, status = Open3.capture3(*command)
    raise "Crush command failed: #{stderr}" unless status.success?

    { command: command, stdout: stdout, stderr: stderr }
  end

  def fetch_group_activity(group, config, client, window)
    gslug = slugify(group)
    group_dir = config[:out_dir].join(gslug)
    raw_dir = group_dir.join('raw')
    ensure_directories(raw_dir)

    puts "→ Fetching group '#{group}'"
    group_json = client.get("/api/v4/groups/#{escape_path_segment(group)}")
    gid = group_json.fetch('id')

    projects = client.paginate("/api/v4/groups/#{gid}/projects", include_subgroups: 'true', with_shared: 'true')
    issues = client.paginate(
      "/api/v4/groups/#{gid}/issues",
      updated_after: "#{window[:start]}T00:00:00Z",
      updated_before: "#{window[:end]}T00:00:00Z",
      scope: 'all',
      state: 'opened'
    )
    merge_requests = client.paginate(
      "/api/v4/groups/#{gid}/merge_requests",
      updated_after: "#{window[:start]}T00:00:00Z",
      updated_before: "#{window[:end]}T00:00:00Z",
      scope: 'all'
    )

    write_json(raw_dir.join('projects.json'), projects)
    write_json(raw_dir.join('issues.json'), issues)
    write_json(raw_dir.join('mrs.json'), merge_requests)

    commits_all = []
    pipelines_all = []
    events_all = []

    projects.each do |project|
      pid = project['id']
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

    write_json(raw_dir.join('commits.all.json'), commits_all)
    write_json(raw_dir.join('pipelines.all.json'), pipelines_all)
    write_json(raw_dir.join('events.all.json'), events_all)

    generate_group_stats(group_dir, commits_all, pipelines_all, issues, merge_requests)

    group_aggregate = {
      'group' => group,
      'window' => { 'since' => window[:start], 'until' => window[:end] },
      'projects' => projects,
      'issues' => issues,
      'merge_requests' => merge_requests,
      'commits' => commits_all,
      'pipelines' => pipelines_all,
      'events' => events_all
    }

    aggregate_path = group_dir.join('group_aggregate.json')
    write_json(aggregate_path, group_aggregate)

    prompt = render_template(
      'group_summary',
      aggregate_path: aggregate_path.to_s,
      group: group,
      window: window
    )

    crush_result = run_crush(prompt, config[:crush_config])
    summary_path = group_dir.join('summary.md')
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
      'window' => { 'since' => window[:start], 'until' => window[:end] },
      'groups' => group_results.map { |result| result[:aggregate] }
    }
    overall_json_path = config[:out_dir].join('overall_aggregate.json')
    write_json(overall_json_path, overall_json)

    prompt = render_template(
      'overall_summary',
      aggregate_path: overall_json_path.to_s,
      window: window,
      groups: group_results.map { |result| { name: result[:group], slug: result[:slug] } }
    )

    crush_result = run_crush(prompt, config[:crush_config])
    overall_md_path = config[:out_dir].join('overall_summary.md')
    overall_md_path.write(crush_result[:stdout])
    puts "✓ Overall summary: #{overall_md_path}"

    mattermost_status = nil
    if config[:mattermost_webhook] && !config[:mattermost_webhook].empty?
      uri = URI.parse(config[:mattermost_webhook])
      payload = { text: crush_result[:stdout] }.to_json
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request.body = payload
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        response = http.request(request)
        mattermost_status = response.code
        unless response.is_a?(Net::HTTPSuccess)
          raise "Mattermost webhook failed: #{response.code} #{response.body}"
        end
      end
      puts '✓ Posted to Mattermost'
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
          'timestamp' => timestamp,
          'inputs' => inputs,
          'outputs' => outputs
        }
      )
    )
    log_path
  end

  def run
    cfg = config
    date = cfg[:date]
    window_start, window_end = week_window(date)
    window = {
      start: window_start.strftime('%F'),
      end: window_end.strftime('%F')
    }

    year_week = iso_week(date)
    cfg[:out_dir] = cfg[:out_root].join(year_week)
    ensure_directories(cfg[:out_dir])

    puts "▶ Weekly window: #{window[:start]} .. #{window[:end]}  →  #{cfg[:out_dir]}"
    puts "▶ Groups: #{cfg[:groups].join(' ')}"

    client = GitlabClient.new(base_url: cfg[:gitlab_base], token: cfg[:gitlab_token], per_page: cfg[:per_page])

    group_results = cfg[:groups].map do |group|
      fetch_group_activity(group, cfg, client, window)
    end

    overall = overall_summary(group_results, window, cfg)

    timestamp = Time.now.utc.strftime('%Y-%m-%d_%H%M%S')
    flow_log_dir = script_dir.join('log')
    inputs = {
      'gitlab_base' => cfg[:gitlab_base],
      'groups' => cfg[:groups],
      'window' => window,
      'per_page' => cfg[:per_page],
      'out_dir' => cfg[:out_dir].to_s,
      'crush_config' => cfg[:crush_config].to_s,
      'mattermost_webhook_configured' => !cfg[:mattermost_webhook].to_s.empty?
    }
    outputs = {
      'groups' => group_results.map do |result|
        {
          'group' => result[:group],
          'aggregate_path' => result[:aggregate_path].to_s,
          'summary_path' => result[:summary_path].to_s,
          'summary' => result[:summary],
          'crush_command' => result[:crush_command]
        }
      end,
      'overall' => {
        'aggregate_path' => overall[:aggregate_path].to_s,
        'summary_path' => overall[:summary_path].to_s,
        'summary' => overall[:summary],
        'crush_command' => overall[:crush_command],
        'mattermost_response_code' => overall[:mattermost_response_code]
      }
    }
    log_path = log_results(flow_log_dir, timestamp, inputs, outputs)
    puts "✓ Logged run: #{log_path}"
  end
end

Pulse.run if $PROGRAM_NAME == __FILE__
