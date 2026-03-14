# frozen_string_literal: true
require "digest"

module Tina4
  module Env
    DEFAULT_ENV = {
      "PROJECT_NAME" => "Tina4 Ruby Project",
      "VERSION" => "1.0.0",
      "TINA4_LANGUAGE" => "en",
      "TINA4_DEBUG_LEVEL" => "[TINA4_LOG_ALL]",
      "SECRET" => "tina4-secret-change-me"
    }.freeze

    class << self
      def load(root_dir = Dir.pwd)
        env_file = resolve_env_file(root_dir)
        unless File.exist?(env_file)
          create_default_env(env_file)
        end
        parse_env_file(env_file)
      end

      private

      def resolve_env_file(root_dir)
        environment = ENV["ENVIRONMENT"]
        if environment && !environment.empty?
          candidate = File.join(root_dir, ".env.#{environment}")
          return candidate if File.exist?(candidate)
        end
        File.join(root_dir, ".env")
      end

      def create_default_env(path)
        api_key = Digest::MD5.hexdigest(Time.now.to_s)
        content = DEFAULT_ENV.map { |k, v| "#{k}=\"#{v}\"" }.join("\n")
        content += "\nAPI_KEY=\"#{api_key}\"\n"
        File.write(path, content)
      end

      def parse_env_file(path)
        return unless File.exist?(path)
        File.readlines(path).each do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")
          if (match = line.match(/\A([A-Za-z_][A-Za-z0-9_]*)=["']?(.*)["']?\z/))
            key = match[1]
            value = match[2].gsub(/["']\z/, "")
            ENV[key] ||= value
          end
        end
      end
    end
  end
end
