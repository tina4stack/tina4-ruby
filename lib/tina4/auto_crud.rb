# frozen_string_literal: true
require "json"

module Tina4
  module AutoCrud
    class << self
      # Track registered model classes
      def models
        @models ||= []
      end

      # Register a model for auto-CRUD
      def register(model_class)
        models << model_class unless models.include?(model_class)
      end

      # Generate REST endpoints for all registered models
      def generate_routes(prefix: "/api")
        models.each do |model_class|
          generate_routes_for(model_class, prefix: prefix)
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

      # Generate REST endpoints for a single model class
      def generate_routes_for(model_class, prefix: "/api")
        table = model_class.table_name
        pk = model_class.primary_key_field || :id
        pretty_name = table.to_s.split("_").map(&:capitalize).join(" ")
        example_body = build_example(model_class)

        # GET /api/{table} -- list all with pagination, filtering, sorting
        Tina4::Router.add("GET", "#{prefix}/#{table}", proc { |req, res|
          begin
            per_page = (req.query["per_page"] || req.query["limit"] || 10).to_i
            page     = (req.query["page"] || 1).to_i
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
              records = model_class.where(where_clause, filter_values)
              total = records.length
              # Apply manual pagination for filtered results
              records = records.slice(offset, limit) || []
            end

            res.json({
              data: records.map { |r| r.to_h },
              total: total,
              limit: limit,
              offset: offset
            })
          rescue => e
            res.json({ error: e.message }, status: 500)
          end
        }, swagger_meta: { summary: "List all #{pretty_name}", tags: [table.to_s] })

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
        }, swagger_meta: { summary: "Get #{pretty_name} by ID", tags: [table.to_s] })

        # POST /api/{table} -- create record
        Tina4::Router.add("POST", "#{prefix}/#{table}", proc { |req, res|
          begin
            attributes = req.body_parsed
            record = model_class.create(attributes)
            if record.persisted?
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
          request_body: {
            "description" => "#{pretty_name} data",
            "required" => true,
            "content" => {
              "application/json" => {
                "schema" => { "type" => "object" },
                "example" => example_body
              }
            }
          }
        })

        # PUT /api/{table}/{id} -- update record
        Tina4::Router.add("PUT", "#{prefix}/#{table}/{id}", proc { |req, res|
          begin
            id = req.params["id"]
            record = model_class.find_by_id(id.to_i)
            unless record
              next res.json({ error: "Not found" }, status: 404)
            end

            attributes = req.body_parsed
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
          request_body: {
            "description" => "#{pretty_name} data",
            "required" => true,
            "content" => {
              "application/json" => {
                "schema" => { "type" => "object" },
                "example" => example_body
              }
            }
          }
        })

        # DELETE /api/{table}/{id} -- delete record
        Tina4::Router.add("DELETE", "#{prefix}/#{table}/{id}", proc { |req, res|
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
      end

      def clear!
        @models = []
      end

      private

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
