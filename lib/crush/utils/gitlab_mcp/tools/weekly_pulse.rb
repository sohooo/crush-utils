# frozen_string_literal: true

require "date"

require "crush/utils/flows/pulse/weekly_pulse"
require "crush/utils/gitlab_mcp/tools/support"

module Crush
  module Utils
    module GitlabMCP
      module Tools
        class WeeklyPulse < MCP::Tool
          tool_name "pulse.weekly"
          description "Run the Weekly Pulse flow for one or more GitLab groups and surface the generated summaries."
          input_schema(
            type: "object",
            properties: {
              config: {
                type: "object",
                description: "Configuration hash passed directly to the Weekly Pulse flow. Must include GitLab credentials and output paths."
              }
            },
            required: ["config"],
            additionalProperties: true
          )

          class << self
            def call(config:, server_context:, **)
              symbolized_config = Support.symbolize_keys(config)

              flow = build_flow(
                config: symbolized_config,
                server_context: server_context
              )

              flow.call

              final_config = extract_final_config(flow, symbolized_config)
              out_dir = Support.path(final_config[:out_dir])

              group_details = Array(final_config[:groups]).map do |group|
                build_group_payload(out_dir, group)
              end

              overall_payload = build_overall_payload(out_dir)

              MCP::Tool::Response.new(
                [
                  {
                    type: "text",
                    text: build_text_response(group_details, overall_payload)
                  }
                ],
                structured_content: {
                  flow: Crush::Utils::Flows::Pulse::WeeklyPulse::FLOW_NAME,
                  out_dir: out_dir&.to_s,
                  groups: group_details,
                  overall: overall_payload
                }.compact
              )
            end

            private

            def build_flow(config:, server_context:)
              factory = server_context[:weekly_pulse_factory]
              clock = server_context[:clock] || Time

              if factory
                factory.call(argv: [], config: config, clock: clock)
              else
                Crush::Utils::Flows::Pulse::WeeklyPulse.new(argv: [], config: config, clock: clock)
              end
            end

            def extract_final_config(flow, fallback)
              if flow.respond_to?(:configuration, true)
                flow.send(:configuration)
              else
                fallback
              end
            end

            def build_group_payload(out_dir, group)
              slug = Support.slugify(group)
              group_dir = out_dir&.join(slug)

              summary_path = group_dir&.join("summary.md")
              aggregate_path = group_dir&.join("group_aggregate.json")

              {
                name: group,
                slug: slug,
                summary_path: summary_path&.to_s,
                summary: Support.read_text(summary_path),
                aggregate_path: aggregate_path&.to_s,
                aggregate: Support.read_json(aggregate_path)
              }.compact
            end

            def build_overall_payload(out_dir)
              summary_path = out_dir&.join("overall_summary.md")
              aggregate_path = out_dir&.join("overall_aggregate.json")

              {
                summary_path: summary_path&.to_s,
                summary: Support.read_text(summary_path),
                aggregate_path: aggregate_path&.to_s,
                aggregate: Support.read_json(aggregate_path)
              }.compact
            end

            def build_text_response(group_details, overall_payload)
              header = "Weekly pulse summaries generated"
              overall_summary = overall_payload[:summary]

              body = if overall_summary && !overall_summary.empty?
                       overall_summary
                     elsif overall_payload[:summary_path]
                       "Overall summary saved to #{overall_payload[:summary_path]}"
                     else
                       group_details.map { |group| "Summary saved to #{group[:summary_path]}" if group[:summary_path] }.compact.join("\n")
                     end

              [header, body].compact.join("\n\n")
            end
          end
        end
      end
    end
  end
end
