# frozen_string_literal: true

require "crush/utils/gitlab_mcp/tools/mr_reviewer"
require "crush/utils/gitlab_mcp/tools/weekly_pulse"

module Crush
  module Utils
    module GitlabMCP
      class Server
        DEFAULT_NAME = "crush_gitlab"

        attr_reader :mcp_server

        def initialize(name: DEFAULT_NAME, server_context: {}, tools: nil, clock: Time)
          context = { clock: clock }.merge(server_context || {})
          @mcp_server = MCP::Server.new(
            name: name,
            tools: tools || default_tools,
            server_context: context
          )
        end

        def handle_json(payload)
          mcp_server.handle_json(payload)
        end

        def transport
          mcp_server.transport
        end

        def transport=(transport)
          mcp_server.transport = transport
        end

        def notify_tools_list_changed
          mcp_server.notify_tools_list_changed
        end

        def notify_prompts_list_changed
          mcp_server.notify_prompts_list_changed
        end

        def notify_resources_list_changed
          mcp_server.notify_resources_list_changed
        end

        def method_missing(name, *args, &block)
          if mcp_server.respond_to?(name)
            mcp_server.public_send(name, *args, &block)
          else
            super
          end
        end

        def respond_to_missing?(name, include_private = false)
          mcp_server.respond_to?(name, include_private) || super
        end

        private

        def default_tools
          [
            Crush::Utils::GitlabMCP::Tools::MrReviewer,
            Crush::Utils::GitlabMCP::Tools::WeeklyPulse
          ]
        end
      end
    end
  end
end
