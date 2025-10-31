# frozen_string_literal: true

require_relative "lib/crush/utils/version"

Gem::Specification.new do |spec|
  spec.name          = "crush-utils"
  spec.version       = Crush::Utils::VERSION
  spec.authors       = ["Unknown"]
  spec.email         = ["unknown@example.com"]

  spec.summary       = "Utilities for running Crush flows"
  spec.description   = "A collection of flow runners and supporting tools for Crush reports."
  spec.homepage      = "https://example.com/crush-utils"
  spec.license       = "MIT"

  spec.required_ruby_version = Gem::Requirement.new(">= 2.7.0")

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://example.com/crush-utils"

  spec.files         = Dir.glob("{bin,lib}/**/*", File::FNM_DOTMATCH).reject { |f| f.end_with?(".", "..") || File.directory?(f) }
  spec.bindir        = "bin"
  spec.executables   = ["crush-utils"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "zeitwerk", ">= 2.6"

  spec.add_development_dependency "bundler", ">= 2.0"
  spec.add_development_dependency "rake", ">= 13.0"
  spec.add_development_dependency "minitest", ">= 5.0"
end
