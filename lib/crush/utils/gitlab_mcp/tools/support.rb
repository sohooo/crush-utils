# frozen_string_literal: true

require "json"
require "pathname"

module Crush
  module Utils
    module GitlabMCP
      module Tools
        module Support
          module_function

          def symbolize_keys(value)
            case value
            when Hash
              value.each_with_object({}) do |(key, val), memo|
                memo[symbolize_key(key)] = symbolize_keys(val)
              end
            when Array
              value.map { |element| symbolize_keys(element) }
            else
              value
            end
          end

          def symbolize_key(key)
            key.respond_to?(:to_sym) ? key.to_sym : key
          end

          def read_json(path)
            return unless path&.file?

            JSON.parse(path.read)
          rescue JSON::ParserError
            nil
          end

          def read_text(path)
            return unless path&.file?

            path.read
          end

          def path(value)
            return if value.nil?

            value.is_a?(Pathname) ? value : Pathname(value)
          end

          def slugify(value)
            value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
          end
        end
      end
    end
  end
end
