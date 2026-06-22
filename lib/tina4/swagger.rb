# frozen_string_literal: true
require "json"

module Tina4
  module Swagger
    class << self
      def generate(routes = [])
        spec = base_spec
        route_list = routes.empty? ? Tina4::Router.routes : routes
        # Accumulators shared across routes: ORM models referenced
        # (-> components.schemas), tags used (-> top-level tags[]), seen
        # operationIds (de-dup — OpenAPI requires them unique).
        ctx = { models: {}, used_tags: [], seen_ids: [] }
        route_list.each do |route|
          add_route_to_spec(spec, route, ctx)
        end

        unless ctx[:models].empty?
          spec["components"]["schemas"] = {}
          ctx[:models].each do |name, klass|
            spec["components"]["schemas"][name] = model_schema(klass)
          end
        end
        spec["tags"] = ctx[:used_tags].map { |t| { "name" => t } } unless ctx[:used_tags].empty?

        spec
      end

      # TINA4_SWAGGER_ENABLED — defaults to TINA4_DEBUG. Wired into RackApp's
      # /swagger serving (v3.13.40), so it genuinely gates whether the docs are
      # served — it was dead code before.
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
          "servers" => servers,
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

      # servers[] — TINA4_SWAGGER_SERVERS (comma-separated) for a multi-server
      # list, else SWAGGER_DEV_URL, else the relative "/" default.
      def servers
        raw = ENV.fetch("TINA4_SWAGGER_SERVERS", "")
        urls = raw.split(",").map(&:strip).reject(&:empty?)
        return urls.map { |u| { "url" => u } } unless urls.empty?

        dev = ENV["SWAGGER_DEV_URL"]
        return [{ "url" => dev }] if dev && !dev.empty?

        [{ "url" => "/" }]
      end

      # Valid OpenAPI path-item methods. Anything else (e.g. "any", a WebSocket
      # "ws") is not a valid key and would make the document spec-invalid.
      HTTP_METHODS = %w[get post put patch delete head options trace].freeze

      def add_route_to_spec(spec, route, ctx)
        method = route.method.downcase
        return unless HTTP_METHODS.include?(method)

        path = convert_path(route.path)
        meta = route.swagger_meta || {}

        # ORM model -> components.schemas + $ref
        ref = nil
        if (model = meta[:model])
          klass = model.is_a?(String) ? resolve_model(model) : model
          if klass
            name = klass.name.split("::").last
            ctx[:models][name] ||= klass
            ref = "#/components/schemas/#{name}"
          end
        end

        tags = meta[:tags] || [extract_tag(route.path)]
        tags.each { |t| ctx[:used_tags] << t unless ctx[:used_tags].include?(t) }

        spec["paths"][path] ||= {}
        operation = {
          "operationId" => unique_operation_id(method, path, ctx[:seen_ids]),
          "summary" => meta[:summary] || "#{method.upcase} #{route.path}",
          "description" => meta[:description] || "",
          "tags" => tags,
          "parameters" => build_parameters(route),
          "responses" => meta[:responses] || model_or_default_responses(ref, meta[:model_list])
        }

        operation["deprecated"] = true if meta[:deprecated]

        if route.auth_handler
          operation["security"] = [{ "bearerAuth" => [] }]
        end

        if %w[post put patch].include?(method)
          operation["requestBody"] = build_request_body(method, meta, ref)
        end

        spec["paths"][path][method] = operation
      end

      def build_request_body(_method, meta, ref)
        return meta[:request_body] if meta[:request_body]

        schema = ref ? { "$ref" => ref } : { "type" => "object" }
        content = { "schema" => schema }
        content["example"] = meta[:example] if meta[:example]
        { "content" => { "application/json" => content } }
      end

      def model_or_default_responses(ref, model_list)
        return default_responses unless ref

        schema = model_list ? { "type" => "array", "items" => { "$ref" => ref } } : { "$ref" => ref }
        {
          "200" => {
            "description" => "Successful response",
            "content" => { "application/json" => { "schema" => schema } }
          }
        }
      end

      def convert_path(path)
        # {id:int} -> {id}
        p = path.gsub(/\{(\w+)(?::\w+)?\}/, '{\1}')
        # splat *path -> {path}; bare /* -> /{wildcard} (a literal '*' segment
        # or an orphaned splat param is invalid OpenAPI templating)
        p = p.gsub(/\*(\w+)/, '{\1}')
        p.gsub(%r{(?<=/)\*(?=/|$)}, "{wildcard}")
      end

      def extract_tag(path)
        parts = path.split("/").reject(&:empty?)
        first = parts.first
        return "default" if first.nil? || first.start_with?("{", "*")

        first
      end

      def unique_operation_id(method, path, seen)
        base = method + path.gsub(%r{[/{}*]}) { |c| c == "*" ? "wildcard" : "_" }
        base = base.gsub(/_+/, "_").chomp("_")
        oid = base
        n = 2
        while seen.include?(oid)
          oid = "#{base}_#{n}"
          n += 1
        end
        seen << oid
        oid
      end

      def build_parameters(route)
        params = []
        route.param_names.each do |param|
          name = param[:name].to_s
          name = "wildcard" if name == "*"
          params << {
            "name" => name,
            "in" => "path",
            "required" => true,
            "schema" => param_schema(param[:type])
          }
        end
        params
      end

      def param_schema(type)
        case type.to_s
        when "int", "integer"
          { "type" => "integer" }
        when "float", "number"
          { "type" => "number" }
        when "uuid"
          { "type" => "string", "format" => "uuid" }
        when "slug"
          { "type" => "string", "pattern" => "^[a-z0-9]+(?:-[a-z0-9]+)*$" }
        when "alpha"
          { "type" => "string", "pattern" => "^[A-Za-z]+$" }
        when "alnum"
          { "type" => "string", "pattern" => "^[A-Za-z0-9]+$" }
        else
          { "type" => "string" }
        end
      end

      # Build a components.schemas object from an ORM model's field definitions.
      def model_schema(model_class)
        props = {}
        required = []
        defs = model_class.respond_to?(:field_definitions) ? model_class.field_definitions : {}
        defs.each do |name, opts|
          props[name.to_s] = field_schema(opts)
          required << name.to_s if opts[:nullable] == false
        end
        schema = { "type" => "object", "properties" => props.empty? ? {} : props }
        schema["required"] = required unless required.empty?
        schema
      end

      def field_schema(opts)
        schema = map_field_type(opts[:type])
        schema["readOnly"] = true if opts[:primary_key] && opts[:auto_increment]
        schema
      end

      def map_field_type(type)
        case type.to_s
        when "integer"
          { "type" => "integer" }
        when "float", "decimal", "numeric"
          { "type" => "number" }
        when "boolean"
          { "type" => "boolean" }
        when "datetime", "date", "timestamp"
          { "type" => "string", "format" => "date-time" }
        when "blob"
          { "type" => "string", "format" => "byte" }
        else
          { "type" => "string" }
        end
      end

      def resolve_model(name)
        Object.const_get(name)
      rescue NameError
        begin
          Tina4.const_get(name)
        rescue NameError
          nil
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
    end
  end
end
