# frozen_string_literal: true
require "json"

module Tina4
  module Swagger
    class << self
      def generate(routes = [])
        spec = base_spec
        route_list = routes.empty? ? Tina4::Router.routes : routes
        route_list.each do |route|
          add_route_to_spec(spec, route)
        end
        spec
      end

      # TINA4_SWAGGER_ENABLED — defaults to TINA4_DEBUG. When false, callers
      # can choose to skip mounting /swagger entirely in production.
      def enabled?
        explicit = ENV["TINA4_SWAGGER_ENABLED"]
        if explicit && !explicit.empty?
          return %w[true 1 yes on].include?(explicit.to_s.strip.downcase)
        end
        %w[true 1 yes on].include?(ENV.fetch("TINA4_DEBUG", "").to_s.strip.downcase)
      end

      private

      def base_spec
        info = {
          "title" => ENV["TINA4_SWAGGER_TITLE"] || ENV["PROJECT_NAME"] || "Tina4 API",
          "version" => ENV["TINA4_SWAGGER_VERSION"] || Tina4::VERSION,
          "description" => ENV["TINA4_SWAGGER_DESCRIPTION"] || "Auto-generated API documentation"
        }

        # Optional contact block — only emitted when at least one field is set.
        contact_email = ENV["TINA4_SWAGGER_CONTACT_EMAIL"]
        contact_team  = ENV["TINA4_SWAGGER_CONTACT_TEAM"] || ENV["SWAGGER_CONTACT_TEAM"]
        contact_url   = ENV["TINA4_SWAGGER_CONTACT_URL"]  || ENV["SWAGGER_CONTACT_URL"]
        contact = {}
        contact["email"] = contact_email if contact_email && !contact_email.empty?
        contact["name"]  = contact_team  if contact_team  && !contact_team.empty?
        contact["url"]   = contact_url   if contact_url   && !contact_url.empty?
        info["contact"] = contact unless contact.empty?

        # Optional license block — TINA4_SWAGGER_LICENSE is the SPDX name (e.g. "MIT").
        license_name = ENV["TINA4_SWAGGER_LICENSE"]
        if license_name && !license_name.empty?
          info["license"] = { "name" => license_name }
        end

        {
          "openapi" => "3.0.3",
          "info" => info,
          "servers" => [
            { "url" => "/" }
          ],
          "paths" => {},
          "components" => {
            "securitySchemes" => {
              "bearerAuth" => {
                "type" => "http",
                "scheme" => "bearer",
                "bearerFormat" => "JWT"
              }
            }
          }
        }
      end

      def add_route_to_spec(spec, route)
        path = convert_path(route.path)
        method = route.method.downcase
        return if method == "any"

        spec["paths"][path] ||= {}
        operation = {
          "summary" => route.swagger_meta[:summary] || "#{method.upcase} #{route.path}",
          "description" => route.swagger_meta[:description] || "",
          "tags" => route.swagger_meta[:tags] || [extract_tag(route.path)],
          "parameters" => build_parameters(route),
          "responses" => route.swagger_meta[:responses] || default_responses
        }

        if route.auth_handler
          operation["security"] = [{ "bearerAuth" => [] }]
        end

        if %w[post put patch].include?(method) && route.swagger_meta[:request_body]
          operation["requestBody"] = route.swagger_meta[:request_body]
        elsif %w[post put patch].include?(method)
          operation["requestBody"] = default_request_body
        end

        spec["paths"][path][method] = operation
      end

      def convert_path(path)
        # Convert {id:int} to {id}
        path.gsub(/\{(\w+)(?::\w+)?\}/, '{\1}')
      end

      def extract_tag(path)
        parts = path.split("/").reject(&:empty?)
        parts.first || "default"
      end

      def build_parameters(route)
        params = []
        route.param_names.each do |param|
          params << {
            "name" => param[:name].to_s,
            "in" => "path",
            "required" => true,
            "schema" => param_schema(param[:type])
          }
        end
        params
      end

      def param_schema(type)
        case type
        when "int", "integer"
          { "type" => "integer" }
        when "float", "number"
          { "type" => "number" }
        else
          { "type" => "string" }
        end
      end

      def default_responses
        {
          "200" => { "description" => "Successful response" },
          "400" => { "description" => "Bad request" },
          "401" => { "description" => "Unauthorized" },
          "404" => { "description" => "Not found" },
          "500" => { "description" => "Internal server error" }
        }
      end

      def default_request_body
        {
          "content" => {
            "application/json" => {
              "schema" => { "type" => "object" }
            }
          }
        }
      end
    end
  end
end
