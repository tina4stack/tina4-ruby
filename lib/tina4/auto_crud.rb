# frozen_string_literal: true
require "json"

module Tina4
  module AutoCrud
    # PAGE-DEC-01: the maximum per-page size the list handler will honour, no
    # matter what a caller asks for via ?limit=/?per_page=. 100 is not an
    # arbitrary pick - it is the SAME row cap ORM.all/db.fetch already default
    # to, and the number Node's AutoCrud shares via its own DEFAULT_ROW_CAP
    # constant. Without this a client could request the whole table in one
    # query (?limit=1000000).
    MAX_PER_PAGE = 100

    class << self
      # Track registered model classes
      def models
        @models ||= []
      end

      # Per-model public-writes flag (model_class => Boolean).
      # Default secure; only set true when a model is registered `public: true`.
      # Mirrors tina4-php's `$this->public` map. Write routes stay gated unless
      # a model is explicitly opted out.
      def public_flags
        @public_flags ||= {}
      end

      # Register a model for auto-CRUD.
      #
      # @param model_class [Class] the ORM subclass to expose
      # @param public [Boolean] when true, the generated write routes
      #   (POST/PUT/DELETE) opt OUT of the framework's secure-by-default write
      #   gate — they are marked `.no_auth`. Default false keeps writes gated
      #   (a valid bearer token is required), matching the router's rule that
      #   POST/PUT/PATCH/DELETE require auth unless explicitly opened. Parity
      #   with tina4-python / tina4-php.
      def register(model_class, public: false)
        models << model_class unless models.include?(model_class)
        public_flags[model_class] = public
      end

      # Generate REST endpoints for all registered models
      def generate_routes(prefix: "/api")
        models.each do |model_class|
          generate_routes_for(model_class, prefix: prefix, public: public_flags[model_class])
        end
      end

      # Build a sample request body from ORM field definitions.
      def build_example(model_class)
        example = {}
        return example unless model_class.respond_to?(:field_definitions)

        model_class.field_definitions.each do |name, opts|
          next if opts[:primary_key] && opts[:auto_increment]

          case opts[:type]
          when :integer
            example[name.to_s] = 0
          when :numeric, :float, :decimal
            example[name.to_s] = 0.0
          when :boolean
            example[name.to_s] = true
          when :datetime
            example[name.to_s] = "2024-01-01T00:00:00"
          else
            example[name.to_s] = "string"
          end
        end
        example
      end

      # Generate REST endpoints for a single model class.
      #
      # @param model_class [Class] the ORM subclass to expose
      # @param prefix [String] URL prefix for the generated routes
      # @param public [Boolean, nil] when true, the write routes
      #   (POST/PUT/DELETE) opt out of the secure-by-default gate via
      #   `.no_auth`. When nil (the default), the flag stored at register()
      #   time is used, falling back to false (secure). The read routes (GET)
      #   are never gated regardless.
      def generate_routes_for(model_class, prefix: "/api", public: nil)
        table = model_class.table_name
        pk = model_class.primary_key_field || :id
        pretty_name = table.to_s.split("_").map(&:capitalize).join(" ")
        example_body = build_example(model_class)

        # Explicit arg wins; otherwise fall back to the flag recorded by
        # register(), otherwise secure-by-default.
        is_public = public.nil? ? (public_flags[model_class] || false) : public

        # GET /api/{table} -- list all with pagination, filtering, sorting
        Tina4::Router.add("GET", "#{prefix}/#{table}", proc { |req, res|
          begin
            per_page = (req.query["per_page"] || req.query["limit"] || 10).to_i
            # PAGE-DEC-01: cap an oversized ?per_page=/?limit= BEFORE it is used to
            # derive offset below, so the offset lines up with the size actually
            # used (a client can no longer request the whole table in one query).
            per_page = [per_page, MAX_PER_PAGE].min
            page     = (req.query["page"] || 1).to_i
            # PAGE-DEC-01: clamp page < 1 -> page 1 BEFORE deriving offset, so
            # offset=(page-1)*per_page can never go negative (page=0/negative used
            # to hand PostgreSQL a negative OFFSET - a driver error - and silently
            # misbehave on SQLite, while the envelope reported page:0).
            page     = [page, 1].max
            limit    = per_page
            offset   = req.query["offset"] ? req.query["offset"].to_i : (page - 1) * per_page
            order_by = parse_sort(req.query["sort"])

            # Filter support: ?filter[field]=value
            filter_conditions = []
            filter_values = []
            req.query.each do |key, value|
              if key =~ /\Afilter\[(\w+)\]\z/
                filter_conditions << "#{$1} = ?"
                filter_values << value
              end
            end

            if filter_conditions.empty?
              records = model_class.all(limit: limit, offset: offset, order_by: order_by)
              total = model_class.count
            else
              where_clause = filter_conditions.join(" AND ")
              # Fetch THIS page in SQL (limit + offset) and take the total from a
              # COUNT(*) over the same filter — never rows-returned, never an
              # in-memory re-slice by the absolute offset (ADR-0043 root causes 2
              # and 3, which returned zero rows for a valid page).
              records = model_class.where(where_clause, filter_values,
                                          limit: limit, offset: offset, order_by: order_by)
              total = model_class.count(where_clause, filter_values)
            end

            # Build the envelope through the ONE canonical derivation — the same
            # DatabaseResult#to_paginate ADR-0043 fixed — so the REST list endpoint
            # can never drift from it again. Exactly seven snake_case keys:
            # records, total, page, per_page, total_pages, limit, offset. `records`
            # is this page verbatim, `total` the true COUNT, and page/per_page/
            # total_pages/limit/offset are all derived from the query that ran.
            page_result = Tina4::DatabaseResult.new(
              records.map { |r| r.to_h }, count: total, limit: limit, offset: offset
            )
            res.json(page_result.to_paginate)
          rescue => e
            res.json({ error: e.message }, status: 500)
          end
        }, swagger_meta: { summary: "List all #{pretty_name}", tags: [table.to_s],
                           model: model_class, model_list: true })

        # GET /api/{table}/{id} -- get single record
        Tina4::Router.add("GET", "#{prefix}/#{table}/{id}", proc { |req, res|
          begin
            id = req.params["id"]
            record = model_class.find_by_id(id.to_i)
            if record
              res.json({ data: record.to_h })
            else
              res.json({ error: "Not found" }, status: 404)
            end
          rescue => e
            res.json({ error: e.message }, status: 500)
          end
        }, swagger_meta: { summary: "Get #{pretty_name} by ID", tags: [table.to_s],
                           model: model_class })

        # POST /api/{table} -- create record
        post_route = Tina4::Router.add("POST", "#{prefix}/#{table}", proc { |req, res|
          begin
            # CRUD-MASS-ASSIGNMENT: allow-list before the body ever reaches
            # the model (guards is_deleted + strips the PK -- see the helper).
            attributes = allow_listed_attributes(model_class, req.body_parsed, is_create: true)
            record = model_class.new(attributes)
            # CRUD-VALIDATION-STATUS (CRUD-DEC-01): build + save directly
            # (not .create, which returns the literal `false` on failure --
            # calling .persisted? on that raised NoMethodError, caught by the
            # generic rescue below as a stray 500). #save already returns
            # self/false and #errors already carries the field messages, so
            # this is the SAME safe pattern the PUT handler uses.
            if record.save
              res.json({ data: record.to_h }, status: 201)
            else
              res.json({ errors: record.errors }, status: 422)
            end
          rescue => e
            res.json({ error: e.message }, status: 500)
          end
        }, swagger_meta: {
          summary: "Create #{pretty_name}",
          tags: [table.to_s],
          # Reference the model's components.schemas entry ($ref, keyed by the
          # model CLASS name) instead of a bare {type:object}; the generated
          # example stays as a sample body. See decisions doc S2.
          model: model_class,
          example: example_body
        })

        # Secure-by-default: only opt out of the write gate when public: true.
        post_route.no_auth if is_public

        # PUT /api/{table}/{id} -- update record
        put_route = Tina4::Router.add("PUT", "#{prefix}/#{table}/{id}", proc { |req, res|
          begin
            id = req.params["id"]
            record = model_class.find_by_id(id.to_i)
            unless record
              next res.json({ error: "Not found" }, status: 404)
            end

            # CRUD-MASS-ASSIGNMENT: allow-list -- the row is addressed by the
            # URL {id}, never by the body (see the helper).
            attributes = allow_listed_attributes(model_class, req.body_parsed, is_create: false)
            attributes.each do |key, value|
              setter = "#{key}="
              record.__send__(setter, value) if record.respond_to?(setter)
            end

            if record.save
              res.json({ data: record.to_h })
            else
              res.json({ errors: record.errors }, status: 422)
            end
          rescue => e
            res.json({ error: e.message }, status: 500)
          end
        }, swagger_meta: {
          summary: "Update #{pretty_name}",
          tags: [table.to_s],
          # $ref the model schema instead of {type:object} (see decisions S2).
          model: model_class,
          example: example_body
        })

        # Secure-by-default: only opt out of the write gate when public: true.
        put_route.no_auth if is_public

        # DELETE /api/{table}/{id} -- delete record
        delete_route = Tina4::Router.add("DELETE", "#{prefix}/#{table}/{id}", proc { |req, res|
          begin
            id = req.params["id"]
            record = model_class.find_by_id(id.to_i)
            unless record
              next res.json({ error: "Not found" }, status: 404)
            end

            if record.delete
              res.json({ message: "Deleted" })
            else
              res.json({ error: "Delete failed" }, status: 500)
            end
          rescue => e
            res.json({ error: e.message }, status: 500)
          end
        }, swagger_meta: { summary: "Delete #{pretty_name}", tags: [table.to_s] })

        # Secure-by-default: only opt out of the write gate when public: true.
        delete_route.no_auth if is_public
      end

      # Discover ORM model classes from a directory and register them.
      #
      # @param models_dir [String] directory to scan (default "src/orm")
      # @param prefix [String] URL prefix for generated routes (default "/api")
      # @param public [Boolean] when true, opt discovered models' write routes
      #   out of the secure-by-default gate (see .register). Default false keeps
      #   writes gated. Parity with tina4-python / tina4-php.
      # @return [Array<String>] list of discovered model class names
      def discover(models_dir = "src/orm", prefix: "/api", public: false)
        discovered = []
        return discovered unless Dir.exist?(models_dir)

        Dir.glob(File.join(models_dir, "*.rb")).each do |file|
          require_relative File.expand_path(file)
        end

        # Find all ORM subclasses that have a table_name
        ObjectSpace.each_object(Class).select { |c| c < Tina4::ORM rescue false }.each do |klass|
          next unless klass.respond_to?(:table_name) && klass.table_name
          register(klass, public: public)
          discovered << klass.name
        end

        generate_routes(prefix: prefix) unless discovered.empty?
        discovered
      end

      def clear!
        @models = []
        @public_flags = {}
      end

      # Alias for parity with other frameworks
      alias_method :clear, :clear!

      private

      # CRUD-MASS-ASSIGNMENT: filter a write body down to writable columns
      # before it ever reaches `.new`/the setter loop. Only DECLARED fields
      # (model_class.field_definitions) pass through; is_deleted is never
      # client-writable (soft-delete is mutated only by #delete/#restore);
      # and the primary key is stripped except a genuinely natural
      # (single-column, non-auto_increment) key on CREATE -- the documented
      # way to choose one (build_example keeps such a key in the sample
      # body). Every other case strips it: an auto-increment CREATE (the
      # database assigns it -- a client-supplied id previously let a POST
      # silently claim/overwrite an unrelated row), and EVERY update (the
      # row is addressed by the URL {id} alone; a body PK would otherwise
      # move #save's own pk_filter WHERE clause off the URL-addressed row).
      def allow_listed_attributes(model_class, data, is_create:)
        return {} unless data.is_a?(Hash)

        defs = model_class.respond_to?(:field_definitions) ? model_class.field_definitions : {}
        pk_fields = model_class.respond_to?(:primary_key_fields) ? model_class.primary_key_fields.map(&:to_s) : []
        single_pk = pk_fields.length == 1 ? pk_fields.first : nil
        auto_increment = single_pk && defs[single_pk.to_sym] && defs[single_pk.to_sym][:auto_increment]
        strip_pk = is_create ? !(single_pk && !auto_increment) : true

        data.each_with_object({}) do |(key, value), allowed|
          key_s = key.to_s
          next unless defs.key?(key_s.to_sym)
          next if key_s == "is_deleted"
          next if strip_pk && pk_fields.include?(key_s)

          allowed[key] = value
        end
      end

      # Parse sort parameter: "-name,created_at" => "name DESC, created_at ASC"
      def parse_sort(sort_str)
        return nil if sort_str.nil? || sort_str.empty?
        sort_str.split(",").map do |field|
          field = field.strip
          if field.start_with?("-")
            "#{field[1..-1]} DESC"
          else
            "#{field} ASC"
          end
        end.join(", ")
      end
    end
  end
end
