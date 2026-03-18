# frozen_string_literal: true

require_relative "lib/tina4/version"

Gem::Specification.new do |spec|
  spec.name = "tina4"
  spec.version = "0.5.2"
  spec.authors = ["Tina4 Team"]
  spec.email = ["info@tina4.com"]
  spec.summary = "Transitional package — use tina4ruby instead."
  spec.description = "This gem has been renamed to tina4ruby. Install tina4ruby for the latest version."
  spec.homepage = "https://tina4.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.files = ["lib/tina4ruby.rb", "lib/tina4/version.rb"]
  spec.require_paths = ["lib"]
  spec.add_dependency "tina4ruby", "~> 0.5"
  spec.post_install_message = "NOTE: The 'tina4' gem has been renamed to 'tina4ruby'. Please update your Gemfile: gem 'tina4ruby'"
end
