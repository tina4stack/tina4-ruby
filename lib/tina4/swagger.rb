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

      private

      def base_spec
        {
          "openapi" => "3.0.3",
          "info" => {
            "title" => ENV["SWAGGER_TITLE"] || ENV["PROJECT_NAME"] || "Tina4 API",
            "version" => ENV["VERSION"] || Tina4::VERSION,
            "description" => "Auto-generated API documentation"
          },
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
