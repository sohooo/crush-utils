# frozen_string_literal: true

require "optparse"

module Crush
  module Utils
    class CLI
      def self.start(argv = ARGV)
        new(argv).run
      end

      def initialize(argv)
        @argv = argv
      end

      def run
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: crush-utils [options] flow_name [flow_args]"
          opts.on("-h", "--help", "Show this help") do
            puts opts
            exit
          end
        end
        parser.parse!(@argv)

        flow_name = @argv.shift
        unless flow_name
          warn "No flow name provided.\n\n#{parser}"
          exit 1
        end

        Crush::Utils::Flows.run(flow_name, argv: @argv)
      rescue Crush::Utils::Flows::UnknownFlowError => e
        warn e.message
        exit 1
      rescue OptionParser::InvalidOption => e
        warn e.message
        warn
        warn parser
        exit 1
      end
    end
  end
end
