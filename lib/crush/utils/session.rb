# frozen_string_literal: true

require "json"
require "pathname"
require "time"
require "fileutils"

module Crush
  module Utils
    class Session
      def initialize(flow_name:, clock: Time, root_dir: nil)
        @flow_name = flow_name.to_s
        @clock = clock
        @root_dir = Pathname(root_dir || default_root_dir)
      end

      def persist!(inputs:, outputs:, timestamp: nil, metadata: {})
        time = normalize_timestamp(timestamp || clock.now)
        payload = {
          "flow" => flow_name,
          "timestamp" => time.iso8601,
          "inputs" => inputs,
          "outputs" => outputs
        }
        metadata = metadata.respond_to?(:compact) ? metadata.compact : metadata
        payload["metadata"] = metadata unless metadata.nil? || metadata.empty?

        path = session_directory.join("#{format_timestamp(time)}.json")
        path.dirname.mkpath
        path.write(JSON.pretty_generate(payload))
        path
      end

      private

      attr_reader :flow_name, :clock, :root_dir

      def default_root_dir
        Crush::Utils.log_dir.join("sessions")
      end

      def session_directory
        root_dir.join(safe_flow_name)
      end

      def safe_flow_name
        flow_name.tr("/\\", "--")
      end

      def format_timestamp(time)
        time.strftime("%Y-%m-%d_%H%M%S")
      end

      def normalize_timestamp(value)
        time =
          case value
          when Time
            value
          else
            value.respond_to?(:to_time) ? value.to_time : value
          end

        unless time.respond_to?(:iso8601)
          raise ArgumentError, "Timestamp must respond to #iso8601"
        end

        time = time.utc if time.respond_to?(:utc)
        time
      end
    end
  end
end
