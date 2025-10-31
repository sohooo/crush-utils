# frozen_string_literal: true

require "crush/utils/flows/gitlab/mr_reviewer"
require "crush/utils/gitlab_mcp/tools/support"

module Crush
  module Utils
    module GitlabMCP
      module Tools
        class MrReviewer < MCP::Tool
          tool_name "gitlab.mr_reviewer"
          description "Run the GitLab merge request reviewer flow and return the generated Crush artefacts."
          input_schema(
            type: "object",
            properties: {
              merge_request_url: {
                type: "string",
                description: "Full GitLab merge request URL."
              },
              config: {
                type: "object",
                description: "Optional configuration overrides passed directly to the flow."
              }
            },
            required: ["merge_request_url"],
            additionalProperties: true
          )

          class << self
            def call(merge_request_url:, config: nil, server_context:, **)
              flow = build_flow(
                argv: [merge_request_url],
                config: Support.symbolize_keys(config),
                server_context: server_context
              )

              result = flow.call || {}

              review_path = Support.path(result[:review_path])
              results_path = Support.path(result[:results_path])
              aggregate_path = Support.path(result[:aggregate_path])

              results_payload = Support.read_json(results_path)
              aggregate_payload = Support.read_json(aggregate_path)

              summary_text = results_payload&.dig("outputs", "summary")
              summary_text = Support.read_text(review_path) if summary_text.nil? || summary_text.empty?

              structured_content = build_structured_content(
                merge_request_url: merge_request_url,
                review_path: review_path,
                results_path: results_path,
                aggregate_path: aggregate_path,
                results_payload: results_payload,
                aggregate_payload: aggregate_payload
              )

              MCP::Tool::Response.new(
                [
                  {
                    type: "text",
                    text: build_text_response(
                      merge_request_url: merge_request_url,
                      review_path: review_path,
                      summary_text: summary_text
                    )
                  }
                ],
                structured_content: structured_content
              )
            end

            private

            def build_flow(argv:, config:, server_context:)
              factory = server_context[:mr_reviewer_factory]
              clock = server_context[:clock] || Time
              client_factory = server_context[:client_factory]
              git_runner = server_context[:git_runner]

              if factory
                factory.call(
                  argv: argv,
                  config: config,
                  client_factory: client_factory,
                  git_runner: git_runner,
                  clock: clock
                )
              else
                Crush::Utils::Flows::Gitlab::MrReviewer.new(
                  argv: argv,
                  config: config,
                  client_factory: client_factory,
                  git_runner: git_runner,
                  clock: clock
                )
              end
            end

            def build_text_response(merge_request_url:, review_path:, summary_text:)
              header = "GitLab merge request review for #{merge_request_url}"
              return header unless review_path || (summary_text && !summary_text.empty?)

              body =
                if summary_text && !summary_text.empty?
                  summary_text
                elsif review_path
                  "Review saved to #{review_path}"
                end

              [header, body].compact.join("\n\n")
            end

            def build_structured_content(merge_request_url:, review_path:, results_path:, aggregate_path:, results_payload:, aggregate_payload:)
              {
                flow: Crush::Utils::Flows::Gitlab::MrReviewer::FLOW_NAME,
                merge_request_url: merge_request_url,
                review_path: review_path&.to_s,
                results_path: results_path&.to_s,
                aggregate_path: aggregate_path&.to_s,
                inputs: results_payload&.dig("inputs"),
                outputs: results_payload&.dig("outputs"),
                aggregate: aggregate_payload
              }.compact
            end
          end
        end
      end
    end
  end
end
