# frozen_string_literal: true
require "json"

module Tina4
  module Swagger
    # Process-wide registries for security schemes and reusable component
    # schemas declared programmatically (add_security_scheme / add_schema).
    # Kept module-level so app bootstrap can register before any generate()
    # call; reset_registry clears them (tests).
    @registered_schemes = {}
    @registered_schemas = {}

    class << self
      # ── Programmatic registries ────────────────────────────────────

      # Register a named OpenAPI security scheme (e.g. an oauth2 scheme with
      # scopes, or a custom apiKey). Call at app bootstrap, before generate().
      #
      #   Tina4::Swagger.add_security_scheme("oauth2", {
      #     "type" => "oauth2",
      #     "flows" => { "clientCredentials" => {
      #       "tokenUrl" => "https://api.example.com/oauth/token",
      #       "scopes" => { "read:users" => "Read users", "write:users" => "Write users" }
      #     } }
      #   })
      def add_security_scheme(name, definition)
        @registered_schemes[name.to_s] = definition
      end

      # Register a reusable component schema, referenceable via
      # swagger_meta[:request_schema] / [:response_schemas] or a raw $ref.
      def add_schema(name, schema)
        @registered_schemas[name.to_s] = schema
      end

      # Clear the security-scheme and schema registries (test helper).
      def reset_registry
        @registered_schemes = {}
        @registered_schemas = {}
      end

      def generate(routes = [])
        spec = base_spec
        route_list = routes.empty? ? Tina4::Router.routes : routes
        # Accumulators shared across routes: ORM models referenced
        # (-> components.schemas), registered custom-schema names referenced
        # by routes, tags used (-> top-level tags[]), seen operationIds
        # (de-dup — OpenAPI requires them unique).
        ctx = { models: {}, ref_schemas: [], used_tags: [], seen_ids: [],
                schemes: spec["components"]["securitySchemes"] }
        route_list.each do |route|
          next unless included?(route.path)

          add_route_to_spec(spec, route, ctx)
        end

        unless ctx[:models].empty? && ctx[:ref_schemas].empty?
          spec["components"]["schemas"] ||= {}
          ctx[:models].each do |name, klass|
            spec["components"]["schemas"][name] = model_schema(klass)
          end
          ctx[:ref_schemas].each do |name|
            next unless @registered_schemas.key?(name)
            next if spec["components"]["schemas"].key?(name)

            spec["components"]["schemas"][name] = @registered_schemas[name]
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
          # info.version is the APPLICATION's API version, not the framework's.
          # Defaulting to Tina4::VERSION made an undocumented app claim API
          # v3.13.x; "1.0.0" is the settled cross-framework default (Python/PHP).
          # TINA4_SWAGGER_VERSION still overrides.
          "version" => ENV["TINA4_SWAGGER_VERSION"] || "1.0.0",
          # Empty by default (parity) — a canned "Auto-generated..." blurb is
          # noise in a real API's docs. Set TINA4_SWAGGER_DESCRIPTION to fill it.
          "description" => ENV["TINA4_SWAGGER_DESCRIPTION"] || ""
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
          "openapi" => resolve_openapi_version(ENV["TINA4_SWAGGER_OPENAPI"]),
          "info" => info,
          "servers" => servers,
          "paths" => {},
          "components" => {
            "securitySchemes" => security_schemes
          }
        }
      end

      # OpenAPI version — default 3.0.3 for broad tool compatibility; opt in to
      # 3.1.0 via TINA4_SWAGGER_OPENAPI=3.1 (the schemas this generator emits
      # are valid in both dialects).
      def resolve_openapi_version(val)
        v = val.to_s.strip
        return "3.0.3" if v.empty?
        return "3.1.0" if %w[3.1 3.1.0].include?(v)
        return "3.0.3" if %w[3.0 3.0.3].include?(v)

        v # honour an explicit full version verbatim
      end

      # Resolve components.securitySchemes from defaults + env + registry.
      def security_schemes
        schemes = {
          "bearerAuth" => {
            "type" => "http",
            "scheme" => "bearer",
            # Default bearer format (the built-in bearerAuth scheme). JWT unless an
            # API uses opaque tokens / API keys as the bearer (e.g. sk_live_...).
            "bearerFormat" => ENV["TINA4_SWAGGER_BEARER_FORMAT"] || "JWT"
          }
        }

        # Optional apiKey scheme — emitted as "apiKeyAuth" when a header/query
        # name is configured (e.g. X-Api-Key).
        api_key_name = ENV["TINA4_SWAGGER_API_KEY_NAME"]
        if api_key_name && !api_key_name.empty?
          api_key_in = ENV["TINA4_SWAGGER_API_KEY_IN"] || "header"
          api_key_in = "header" unless %w[header query cookie].include?(api_key_in)
          schemes["apiKeyAuth"] = {
            "type" => "apiKey",
            "name" => api_key_name,
            "in" => api_key_in
          }
        end

        # Registered schemes win (let an app override bearerAuth or add oauth2).
        @registered_schemes.each { |name, defn| schemes[name] = defn }
        schemes
      end

      # Which scheme secured routes use by default when no per-route security
      # is declared.
      def default_scheme
        scheme = ENV["TINA4_SWAGGER_DEFAULT_SCHEME"]
        scheme && !scheme.empty? ? scheme : "bearerAuth"
      end

      # Framework-internal route prefixes that are NEVER part of an
      # application's public API document. SHARED across all four frameworks
      # (SWAG-EXCLUSION-NOT-SHARED, ADR-0004) so the exclusion is one rule
      # everywhere, not three mechanisms: the dev tools (/swagger, /__dev),
      # the feedback widget (/__feedback), and the built-in AI/RAG service
      # probes (/ai, /rag, /vision, /embed, /image). Ruby dispatches these
      # OUTSIDE Tina4::Router today, so most never reach included? in
      # practice — the list is here so the RULE holds regardless of how a
      # given route got registered, not because of where each internal
      # happens to be wired.
      INTERNAL_PREFIXES = ["/swagger", "/__dev", "/__feedback", "/ai", "/rag", "/vision", "/embed", "/image"].freeze

      # Path filtering. Framework internals (INTERNAL_PREFIXES) are ALWAYS
      # excluded; then TINA4_SWAGGER_INCLUDE (allow-list) / _EXCLUDE apply.
      def included?(raw_path)
        INTERNAL_PREFIXES.each do |internal|
          return false if raw_path == internal || raw_path.start_with?("#{internal}/")
        end

        includes = csv(ENV["TINA4_SWAGGER_INCLUDE"])
        unless includes.empty?
          matched = includes.any? { |p| raw_path == p || raw_path.start_with?(p) }
          return false unless matched
        end

        excludes = csv(ENV["TINA4_SWAGGER_EXCLUDE"])
        return false if excludes.any? { |p| raw_path == p || raw_path.start_with?(p) }

        true
      end

      def csv(val)
        val.to_s.split(",").map(&:strip).reject(&:empty?)
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

        security = resolve_security(meta, route, ctx[:schemes])

        spec["paths"][path] ||= {}
        operation = {
          "operationId" => unique_operation_id(method, path, ctx[:seen_ids]),
          "summary" => meta[:summary] || "#{method.upcase} #{route.path}",
          "tags" => tags,
          "parameters" => build_parameters(route),
          "responses" => build_responses(meta, ref, ctx)
        }
        # description is OMITTED when unset (SWAG-SHAPE-DRIFT, ADR-0004) —
        # python/php/node never fabricate a description key either; Ruby used
        # to always stamp "" on every undecorated operation, the one shape
        # drift where Ruby (not Python) was the odd one out.
        operation["description"] = meta[:description] if meta[:description]

        operation["deprecated"] = true if meta[:deprecated]
        operation["security"] = security unless security.nil?

        # A route emits 401 WHEN AND ONLY WHEN it is documented as secured (a
        # non-empty security requirement). An undecorated route carries only
        # 200; nothing invents 400/404/500, and an explicitly public route
        # (security == []) gets no 401. Mirrors PHP; drops the old
        # default_responses that stamped 200/400/401/404/500 on every operation
        # including a public GET.
        if security && !security.empty? && !operation["responses"].key?("401")
          operation["responses"]["401"] = { "description" => "Unauthorized" }
        end

        if %w[post put patch].include?(method)
          operation["requestBody"] = build_request_body(method, meta, ref, ctx)
        end

        spec["paths"][path][method] = operation
      end

      # Auth — explicit per-route security wins (an explicit "public"/[] = no
      # security); otherwise a secured route gets the default scheme. Returns
      # nil when the route declares nothing and is not secured (omit the key).
      def resolve_security(meta, route, schemes)
        if meta.key?(:security)
          reqs = normalize_security(meta[:security], meta[:scopes])
          return reqs.empty? ? [] : sanitize_security(reqs, schemes)
        end

        # auth_required is what DISPATCH enforces: true by default on
        # POST/PUT/PATCH/DELETE, flipped by `.secure` / `.no_auth`. This branch
        # read `auth_handler` instead, which defaults to nil and is set only by
        # the `auth:` keyword or the secure_* helpers - so every write route
        # registered the ordinary way was enforced-secured and documented
        # PUBLIC, and `.secure` on a GET never reached the document at all.
        # MEASURED: POST /api/items answered 401 while its operation carried no
        # security key, in the framework's own AutoCrud output too.
        #
        # Both flags are honoured. A custom auth_handler protects a route even
        # when auth_required is false for its method, so it is still documented.
        return sanitize_security([{ default_scheme => [] }], schemes) if route.auth_required || route.auth_handler

        nil
      end

      # Normalize swagger_meta[:security] to an OpenAPI security-requirement list.
      #
      #   security: "oauth2", scopes: ["read"]   -> [{"oauth2" => ["read"]}]
      #   security: { "bearerAuth" => [] }        -> [{"bearerAuth" => []}]   (AND within one map)
      #   security: [{"oauth2"=>["read"]}, {...}] -> verbatim (OR across maps)
      #   security: "public" / []                 -> [] (explicitly no auth)
      def normalize_security(value, scopes)
        scope_list = Array(scopes).map(&:to_s)
        if value.nil? || value == [] || (value.is_a?(String) && %w[public none].include?(value))
          return []
        end

        case value
        when String
          [{ value => scope_list }]
        when Hash
          [value.each_with_object({}) { |(k, v), h| h[k.to_s] = Array(v).map(&:to_s) }]
        when Array
          value.map { |req| req.each_with_object({}) { |(k, v), h| h[k.to_s] = Array(v).map(&:to_s) } }
        else
          []
        end
      end

      # Keep a security-requirement list spec-valid: scopes are allowed only on
      # oauth2/openIdConnect schemes; everything else gets an empty array
      # (OpenAPI requires that for http/apiKey).
      def sanitize_security(reqs, schemes)
        scope_ok = %w[oauth2 openIdConnect]
        reqs.map do |req|
          req.each_with_object({}) do |(name, scopes), clean|
            stype = (schemes[name] || {})["type"]
            clean[name] = scope_ok.include?(stype) ? Array(scopes) : []
          end
        end
      end

      def build_request_body(_method, meta, ref, ctx)
        return meta[:request_body] if meta[:request_body]

        # Registered custom request schema ($ref) wins over the ORM-model ref.
        if (req_schema = meta[:request_schema])
          name, content_type = request_schema_parts(req_schema)
          ctx[:ref_schemas] << name unless ctx[:ref_schemas].include?(name)
          content = { "schema" => { "$ref" => "#/components/schemas/#{name}" } }
          content["example"] = meta[:example] if meta[:example]
          return { "content" => { content_type => content } }
        end

        schema = ref ? { "$ref" => ref } : { "type" => "object" }
        content = { "schema" => schema }
        content["example"] = meta[:example] if meta[:example]
        { "content" => { "application/json" => content } }
      end

      # swagger_meta[:request_schema] accepts "Name" or { name:, content_type: }.
      def request_schema_parts(req_schema)
        if req_schema.is_a?(Hash)
          [(req_schema[:name] || req_schema["name"]).to_s,
           (req_schema[:content_type] || req_schema["content_type"] || "application/json").to_s]
        else
          [req_schema.to_s, "application/json"]
        end
      end

      def build_responses(meta, ref, ctx)
        return meta[:responses] if meta[:responses]

        responses = model_or_default_responses(ref, meta[:model_list])

        # Registered response schemas ($ref) — explicit and authoritative.
        if (resp_schemas = meta[:response_schemas])
          resp_schemas.each do |status, spec|
            name, is_list = response_schema_parts(spec)
            ctx[:ref_schemas] << name unless ctx[:ref_schemas].include?(name)
            sref = "#/components/schemas/#{name}"
            schema = is_list ? { "type" => "array", "items" => { "$ref" => sref } } : { "$ref" => sref }
            responses[status.to_s] = {
              "description" => status.to_s.start_with?("2") ? "Successful response" : "Response",
              "content" => { "application/json" => { "schema" => schema } }
            }
          end
        end

        responses
      end

      # A response-schema entry is "Name", { name:, list: } or [name, is_list].
      def response_schema_parts(spec)
        case spec
        when Hash
          [(spec[:name] || spec["name"]).to_s,
           !!(spec[:list] || spec["list"] || spec[:is_list] || spec["is_list"])]
        when Array
          [spec[0].to_s, !!spec[1]]
        else
          [spec.to_s, false]
        end
      end

      # A route's success response. An undecorated route emits ONLY 200
      # (description-only); with a model ref the 200 carries the schema. The
      # 401-on-secured addition happens in add_route_to_spec, not here.
      def model_or_default_responses(ref, model_list)
        unless ref
          return { "200" => { "description" => "Successful response" } }
        end

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

      # operationId is a generated client's METHOD NAME, so two distinct paths
      # must produce two distinct ids. Preserve the path's own underscores —
      # /__health -> get___health, /health -> get_health — instead of collapsing
      # both to get_health and suffixing _2 onto whichever registered second
      # (order-dependent). Mirrors the Python master: strip the outer slashes,
      # turn internal "/" into "_", drop the {} around params, map a splat to
      # "wildcard", and DO NOT collapse repeated underscores.
      def unique_operation_id(method, path, seen)
        clean = path.gsub(%r{\A/+|/+\z}, "")
                    .gsub("/", "_")
                    .delete("{}")
                    .gsub("*", "wildcard")
        base = clean.empty? ? method : "#{method}_#{clean}"
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
    end
  end
end
