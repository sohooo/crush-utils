# frozen_string_literal: true

module Crush
  module Utils
    module Flows
      class UnknownFlowError < Error
        def initialize(name)
          super("Unknown flow: #{name}")
        end
      end

      class << self
        def register(name, flow_class)
          registry[name.to_s] = flow_class
        end

        def run(name, argv: [])
          Crush::Utils.loader.eager_load_namespace(Flows)
          flow_class = registry[name.to_s]
          raise UnknownFlowError, name unless flow_class

          flow_class.new(argv: argv).call
        end

        private

        def registry
          @registry ||= {}
        end
      end
    end
  end
end
