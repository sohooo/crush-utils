# frozen_string_literal: true

require "zeitwerk"
require "pathname"

module Crush
  module Utils
    class Error < StandardError; end

    ROOT = Pathname(__dir__).join("..", "..").expand_path
    LOG_DIR = ROOT.join("log")

    class << self
      def loader
        @loader ||= Zeitwerk::Loader.for_gem.tap do |loader|
          loader.inflector.inflect(
            "cli" => "CLI",
            "mcp" => "MCP",
            "gitlab_mcp" => "GitlabMCP"
          )
          loader.setup
        end
      end

      def root
        ROOT
      end

      def log_dir
        LOG_DIR
      end
    end
  end
end

Crush::Utils.loader
