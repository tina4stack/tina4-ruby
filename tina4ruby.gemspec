# frozen_string_literal: true

require_relative "lib/tina4/version"

Gem::Specification.new do |spec|
  spec.name = "tina4ruby"
  spec.version = Tina4::VERSION
  spec.authors = ["Tina4 Team"]
  spec.email = ["info@tina4.com"]
  spec.summary = "Tina4 for Ruby — 54 built-in features, zero dependencies"
  spec.description = "TINA4: The Intelligent Native Application 4ramework for Ruby — Simple. Fast. Human. Built for AI. Built for you. 54 built-in features, zero dependencies. Full parity with Python, PHP, and Node.js."
  spec.homepage = "https://tina4.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.files = Dir.glob("{lib,exe}/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.bindir = "exe"
  spec.executables = ["tina4ruby"]
  spec.require_paths = ["lib"]
  spec.add_dependency "rack", "~> 3.0"
  spec.add_dependency "rackup", "~> 2.1"
  spec.add_dependency "puma", "~> 6.0"
  spec.add_dependency "dotenv", "~> 3.0"
  spec.add_dependency "jwt", "~> 2.7"
  spec.add_dependency "bcrypt", "~> 3.1"

  spec.add_dependency "net-smtp", "~> 0.5"
  spec.add_dependency "net-imap", "~> 0.5"
  spec.add_dependency "json", "~> 2.7"
  spec.add_dependency "oj", "~> 3.16"
  spec.add_dependency "rexml", "~> 3.2"
  spec.add_dependency "webrick", "~> 1.8"
  spec.add_development_dependency "listen", "~> 3.8"
  spec.add_development_dependency "sqlite3", "~> 2.0"
  spec.add_development_dependency "pg", "~> 1.5"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop", "~> 1.50"
end
