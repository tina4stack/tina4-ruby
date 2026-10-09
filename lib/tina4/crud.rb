# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "json"
require "uri"

module Tina4
  # Crud (ADR-0094) — a FRONTEND over AutoCrud.
  #
  # `to_crud` renders a complete server-rendered admin UI (searchable, sortable,
  # paginated table + create/edit/delete modals) for an ORM model. It owns NO
  # backend routes: the entire REST backend (GET list, GET /{id}, POST, PUT,
  # DELETE, secure-by-default) is delegated to `Tina4::AutoCrud`, and the UI's
  # JavaScript talks to those routes over fetch(). The HTML comes from four
  # app-overridable Frond templates under `crud/` (page, table, form, modals),
  # rendered through `Tina4::Template.render` — the same app-first-then-gem
  # resolution the error pages use — so an app restyles the admin by dropping its
  # own `templates/crud/<name>.twig`, no framework fork.
  #
  # Usage:
  #   Tina4.get "/admin/users" do |request, response|
  #     response.html(Tina4::Crud.to_crud(request, model: User, title: "Users"))
  #   end
  #
  # A custom `sql:` only shapes the LISTING grid (a filter/join/projection); the
  # model still drives columns, the primary key, and every write path, so a
  # custom listing can never create an unauthenticated or divergent write route.
  module Crud
    class << self
      # Render the CRUD admin page for +model+ and register its AutoCrud routes.
      #
      # @param request [Tina4::Request] the current request
      # @param options [Hash, nil] options as a Hash (also accepted as keywords)
      # @option options [Class]   :model  REQUIRED — the ORM model class
      # @option options [String]  :sql    optional listing query (inferred from
      #   the model when omitted); shapes only the displayed grid
      # @option options [String]  :title  page title (default "CRUD")
      # @option options [String]  :prefix AutoCrud route prefix (default "/api")
      # @option options [Integer] :limit  records per page (default 10)
      # @return [String] the rendered crud/page template
      def to_crud(request, options = nil, **kwargs)
        opts = {}
        opts.merge!(options) if options.is_a?(Hash)
        opts.merge!(kwargs)

        model = opts[:model]
        raise ArgumentError, "Crud.to_crud requires a :model (an ORM class)" unless model

        sql    = opts[:sql]
        title  = (opts[:title] || "CRUD").to_s
        prefix = (opts[:prefix] || "/api").to_s
        limit  = (opts[:limit] || 10).to_i
        limit  = 10 if limit <= 0

        table_name = model.table_name.to_s
        pk         = (model.primary_key_field || :id).to_s
        columns    = model.field_definitions.keys.map(&:to_s)

        # Backend: delegate 100% to AutoCrud (idempotent — register once).
        register_backend(model, prefix)

        # Pagination / search / safe-sort from the query string.
        query_params = request.respond_to?(:query) ? (request.query || {}) : {}
        page     = [(query_params["page"] || 1).to_i, 1].max
        search   = query_params["search"].to_s.strip
        sort_col = crud_sort_column(model, sql, query_params["sort"], pk)
        sort_dir = query_params["sort_dir"] == "desc" ? "desc" : "asc"
        offset   = (page - 1) * limit

        if sql
          records, total = fetch_sql_data(sql, search: search, sort: sort_col,
                                          sort_dir: sort_dir, limit: limit, offset: offset)
        else
          records, total = fetch_model_data(model, search: search, sort: sort_col,
                                            sort_dir: sort_dir, limit: limit, offset: offset)
        end

        total_pages  = total > 0 ? (total.to_f / limit).ceil : 1
        api_path     = "#{prefix}/#{table_name}"
        request_path = request.respond_to?(:path) ? request.path.to_s : "/"

        render_page(
          title: title, table_name: table_name, pk: pk, columns: columns,
          records: records, page: page, total_pages: total_pages, total: total,
          limit: limit, search: search, sort_col: sort_col, sort_dir: sort_dir,
          api_path: api_path, request_path: request_path, model: model
        )
      end

      # Render an HTML table fragment from an array of record hashes via
      # crud/table.twig. Inline-editable (contenteditable cells + Save/Delete
      # buttons wired through the template's delegated listener).
      def generate_table(records, table_name: "data", primary_key: "id", editable: true)
        records = records || []
        columns = records.empty? ? [] : records.first.keys.map(&:to_s)

        Tina4::Template.render("crud/table.twig",
          table_data(columns: columns, records: records, pk: primary_key.to_s,
                     table_name: table_name.to_s, editable: editable, sortable: false,
                     inline_script: editable, request_path: nil, search: "",
                     sort_col: nil, sort_dir: "asc", page: 1, limit: 10,
                     table_id: "crud-#{table_name}"))
      end

      # Render an HTML form from a field-definition array via crud/form.twig.
      # +fields+ is an array of { name:, type:, label:, value:, required:, options: }.
      def generate_form(fields, action: "/", method: "POST", table_name: "data")
        verb = method.to_s.upcase
        Tina4::Template.render("crud/form.twig", {
          "wrap" => true,
          "form_id_attr" => "",
          "action" => h(action),
          "form_method" => h(verb),
          "method_override" => (%w[PUT PATCH DELETE].include?(verb) ? verb : nil),
          "edit" => false,
          "modal_footer" => false,
          "submit_button" => true,
          "fields" => (fields || []).map { |f| build_custom_field(f) }
        })
      end

      private

      # Track which (prefix, model) pairs have had their AutoCrud routes built.
      def registered_tables
        @registered_tables ||= {}
      end

      # Delegate the ENTIRE backend to AutoCrud. Idempotent: register + generate
      # once per (prefix, model); Router.add replaces a re-registered route in
      # place, so a second call is harmless either way.
      def register_backend(model, prefix)
        key = "#{prefix}::#{model.name || model.object_id}"
        return if registered_tables[key]

        # Register only if the app has not already done so (e.g. a scaffolded
        # admin route that registered it `public: true`) — re-registering would
        # reset that public flag back to secure. generate_routes is idempotent
        # (Router.add replaces a route in place).
        Tina4::AutoCrud.register(model) unless Tina4::AutoCrud.models.include?(model)
        Tina4::AutoCrud.generate_routes(prefix: prefix)
        registered_tables[key] = true
      end

      # Build the page template data and render page + table + modals (each via
      # Tina4::Template.render, so every sub-template is independently
      # app-overridable).
      def render_page(title:, table_name:, pk:, columns:, records:, page:,
                      total_pages:, total:, limit:, search:, sort_col:, sort_dir:,
                      api_path:, request_path:, model:)
        editable_columns = columns.reject { |c| c.to_s == pk.to_s }

        table_html = Tina4::Template.render("crud/table.twig",
          table_data(columns: columns, records: records, pk: pk,
                     table_name: table_name, editable: false, sortable: true,
                     inline_script: false, request_path: request_path,
                     search: search, sort_col: sort_col, sort_dir: sort_dir,
                     page: page, limit: limit, table_id: nil, model: model))

        modals_html = render_modals(editable_columns, pk)

        Tina4::Template.render("crud/page.twig", {
          "title" => h(title),
          "search" => h(search),
          "request_path" => h(request_path),
          "info_count" => records.length,
          "info_total" => total,
          "info_page" => page,
          "info_total_pages" => total_pages,
          "table_html" => table_html,
          "modals_html" => modals_html,
          "show_pagination" => total_pages > 1,
          "controls" => page_controls(page, total_pages, request_path, search, sort_col, sort_dir, limit),
          "config_json" => js_config(
            api_path: api_path, pk: pk, columns: columns, editable: editable_columns,
            model: model, limit: limit, search: search, sort_col: sort_col,
            sort_dir: sort_dir, page: page
          )
        })
      end

      # Render the create/edit/delete modal shell (crud/modals.twig), with the
      # create and edit forms rendered through crud/form.twig.
      def render_modals(editable_columns, pk)
        Tina4::Template.render("crud/modals.twig", {
          "create_form" => render_modal_form("create", editable_columns, pk, edit: false),
          "edit_form" => render_modal_form("edit", editable_columns, pk, edit: true)
        })
      end

      # A modal's create/edit form — fields + the Cancel/Save footer — via
      # crud/form.twig.
      def render_modal_form(mode, columns, pk, edit:)
        fields = columns.map do |col|
          label = pretty_label(col)
          {
            "id" => "#{mode}-#{col}",
            "name" => h(col),
            "label" => h(label),
            "value" => "",
            "placeholder" => h("Enter #{label.downcase}"),
            "type" => "text",
            "required_attr" => "",
            "input" => true
          }
        end

        Tina4::Template.render("crud/form.twig", {
          "wrap" => true,
          "form_id_attr" => " id=\"form-#{mode}\"",
          "action" => "",
          "form_method" => "POST",
          "method_override" => nil,
          "edit" => edit,
          "mode" => mode,
          "pk" => h(pk),
          "modal_footer" => true,
          "submit_button" => false,
          "fields" => fields
        })
      end

      # Build the data hash crud/table.twig consumes: escaped headers (with sort
      # links + indicator + per-column alignment when sortable), rows carrying
      # pre-joined escaped+aligned <td> cell HTML, and the mutually-exclusive
      # editable/readonly flags. Numeric columns align right (text-end), text
      # columns align left (text-start); the Actions column is always text-end.
      def table_data(columns:, records:, pk:, table_name:, editable:, sortable:,
                     inline_script:, request_path:, search:, sort_col:, sort_dir:,
                     page:, limit:, table_id:, model: nil)
        aligns = columns.map { |col| column_alignment(model, col) }

        headers = columns.each_with_index.map do |col, index|
          header = { "label" => h(pretty_label(col)), "align" => aligns[index] }
          if sortable
            next_dir = (sort_col.to_s == col.to_s && sort_dir == "asc") ? "desc" : "asc"
            header["sortable"] = true
            header["col"] = h(col)
            header["next_dir"] = next_dir
            header["url"] = sort_url(request_path, col, next_dir, page, search, limit)
            header["indicator"] = sort_indicator(sort_col, col, sort_dir)
          else
            header["plain"] = true
          end
          header
        end

        rows = records.map do |record|
          { "id" => h(record_pk(record, pk)),
            "cells" => build_cells(columns, record, editable, aligns) }
        end

        {
          "headers" => headers,
          "rows" => rows,
          "empty" => records.empty?,
          "colspan" => columns.length + 1,
          "editable" => editable,
          "readonly" => !editable,
          "inline_script" => inline_script,
          "table_name" => h(table_name),
          "table_id_attr" => (table_id ? " id=\"#{h(table_id)}\"" : "")
        }
      end

      # The pre-joined <td> cells for one row, every value HTML-escaped and
      # carrying its column alignment class. The <td> tag is the smallest
      # fragment the limited template engine cannot iterate itself (it has no
      # nested-loop support), so it is assembled here; the table structure,
      # headers and action buttons all live in crud/table.twig.
      def build_cells(columns, record, editable, aligns)
        columns.each_with_index.map do |col, index|
          value = h(cell_value(record, col))
          css = aligns[index]
          if editable
            "<td class=\"#{css}\" contenteditable=\"true\" data-field=\"#{h(col)}\">#{value}</td>"
          else
            "<td class=\"#{css}\">#{value}</td>"
          end
        end.join
      end

      # Column alignment from the model's declared field type: numeric columns
      # (integer/numeric/float/decimal) align right, everything else left. With
      # no model (the generate_table fragment), every column aligns left.
      def column_alignment(model, col)
        return "text-start" unless model&.respond_to?(:field_definitions)

        type = model.field_definitions.dig(col.to_sym, :type)
        %i[integer numeric float decimal].include?(type) ? "text-end" : "text-start"
      end

      def cell_value(record, col)
        return record[col.to_sym] if record.respond_to?(:key?) && record.key?(col.to_sym)
        return record[col.to_s] if record.respond_to?(:key?) && record.key?(col.to_s)
        record[col.to_sym] || record[col.to_s] || (record[col] rescue nil)
      end

      def record_pk(record, pk)
        cell_value(record, pk)
      end

      # A field hash for crud/form.twig built from a generate_form field def.
      def build_custom_field(field)
        name     = field[:name].to_s
        label    = field[:label] || name.capitalize
        value    = field[:value]
        required = field[:required] ? " required" : ""

        base = {
          "id" => h(name),
          "name" => h(name),
          "label" => h(label.to_s),
          "value" => h(value.to_s),
          "placeholder" => "",
          "required_attr" => required
        }

        case (field[:type] || :string).to_sym
        when :text
          base.merge("textarea" => true)
        when :boolean
          base.merge("checkbox" => true, "checked_attr" => (value ? " checked" : ""))
        when :select
          base.merge("select" => true, "options_html" => build_options(field[:options], value))
        when :date
          base.merge("input" => true, "type" => "date")
        when :integer, :number, :float, :decimal
          base.merge("input" => true, "type" => "number")
        else
          base.merge("input" => true, "type" => "text")
        end
      end

      def build_options(options, selected_value)
        (options || []).map do |opt|
          selected = opt[:value].to_s == selected_value.to_s ? " selected" : ""
          "<option value=\"#{h(opt[:value])}\"#{selected}>#{h(opt[:label])}</option>"
        end.join
      end

      # tina4: ADR-0069 - ?sort reaches ORDER BY only as a column the source
      # itself declares: a model's declared field (resolved to its DB column) or
      # a column of the SQL query's own result set. Anything else falls back to
      # the primary key - this is a rendered page, not an API, so a bad sort is
      # ignored, never an error.
      def crud_sort_column(model, sql, requested, pk)
        return pk if requested.nil? || requested.empty?
        return model.resolve_field_column(requested) || pk if model && sql.nil?
        return model.resolve_field_column(requested) || pk if model && !sql_result_columns(sql).include?(requested)

        sql ? (sql_result_columns(sql).include?(requested) ? requested : pk) : pk
      end

      # Fetch a page of records from the model (ADR-0069 safe search across the
      # model's string/text columns).
      def fetch_model_data(model, search: "", sort: "id", sort_dir: "asc", limit: 10, offset: 0)
        order_by = "#{sort} #{sort_dir.upcase}"

        if search.empty?
          records = model.all(limit: limit, offset: offset, order_by: order_by)
          total = model.count
        else
          searchable = model.field_definitions.select { |_, opts|
            %i[string text].include?(opts[:type])
          }.keys
          if searchable.empty?
            records = model.all(limit: limit, offset: offset, order_by: order_by)
            total = model.count
          else
            where_clause = searchable.map { |col| "#{col} LIKE ?" }.join(" OR ")
            params = searchable.map { "%#{search}%" }
            all_matches = model.where(where_clause, params, order_by: order_by)
            total = all_matches.length
            records = all_matches.slice(offset, limit) || []
          end
        end

        [records.map(&:to_h), total]
      end

      # Fetch a page of rows for a custom listing SQL. The SQL shapes the DISPLAY
      # only; writes/GET always go through AutoCrud.
      def fetch_sql_data(sql, search: "", sort: "id", sort_dir: "asc", limit: 10, offset: 0)
        db = Tina4.database
        return [[], 0] unless db

        base = strip_order_and_limit(sql)

        if search.empty?
          query = "#{base} ORDER BY #{sort} #{sort_dir.upcase}"
          count_sql = "SELECT COUNT(*) as cnt FROM (#{base}) AS _crud_cnt"
          count_result = db.fetch_one(count_sql)
          total = count_result ? (count_result[:cnt] || count_result["cnt"] || 0).to_i : 0
          results = db.fetch(query, [], limit: limit, offset: offset)
        else
          columns = extract_columns(sql)
          search_parts = columns.map { |col| "CAST(#{col} AS TEXT) LIKE ?" }
          wrapped = "SELECT * FROM (#{base}) AS _crud_sub WHERE #{search_parts.join(' OR ')} ORDER BY #{sort} #{sort_dir.upcase}"
          params = columns.map { "%#{search}%" }
          count_sql = "SELECT COUNT(*) as cnt FROM (#{base}) AS _crud_cnt WHERE #{search_parts.join(' OR ')}"
          count_result = db.fetch_one(count_sql, params)
          total = count_result ? (count_result[:cnt] || count_result["cnt"] || 0).to_i : 0
          results = db.fetch(wrapped, params, limit: limit, offset: offset)
        end

        records = results.respond_to?(:records) ? results.records : results.to_a
        [records, total]
      end

      # The query with any ORDER BY / LIMIT clause removed, line by line with
      # plain string operations so it stays linear on any input.
      def strip_order_and_limit(sql)
        sql.to_s.each_line.map do |line|
          cut_from_keyword(cut_from_keyword(line, /ORDER BY /i), /LIMIT /i)
        end.join.strip
      end

      def cut_from_keyword(line, keyword)
        ending = line.end_with?("\n") ? "\n" : ""
        content = ending.empty? ? line : line[0...-1]
        at = content.index(keyword)
        return line if at.nil? || content.length <= at + keyword.source.length

        content[0...at] + ending
      end

      def sql_result_columns(sql)
        db = Tina4.database
        return [] unless db

        base = strip_order_and_limit(sql)
        row = db.fetch("SELECT * FROM (#{base}) AS _crud_sub", [], limit: 1).first
        row ? row.keys.map(&:to_s) : []
      end

      def extract_columns(sql)
        match = sql.match(/SELECT\s+(.+?)\s+FROM/im)
        return ["*"] unless match

        cols_str = match[1].strip
        return ["*"] if cols_str == "*"

        cols_str.split(",").map do |c|
          c = c.strip
          if c =~ /\bAS\s+(\w+)/i
            Regexp.last_match(1)
          elsif c.include?(".")
            c.split(".").last.strip
          else
            c
          end
        end
      end

      # One flat list of pagination controls (Prev, numbered pages, Next) for
      # crud/page.twig. Each carries exactly one of active/inactive, so the
      # template renders them with a single loop and no nested if/else (the
      # limited engine does not support a nested conditional).
      def page_controls(page, total_pages, request_path, search, sort_col, sort_dir, limit)
        return [] if total_pages <= 1

        controls = []
        if page > 1
          controls << { "label" => "Prev", "page" => page - 1, "active" => false, "inactive" => true,
                        "url" => page_url(request_path, page - 1, search, sort_col, sort_dir, limit) }
        end

        start_page = [page - 3, 1].max
        end_page   = [start_page + 6, total_pages].min
        start_page = [end_page - 6, 1].max
        (start_page..end_page).each do |p|
          controls << { "label" => p, "page" => p, "active" => (p == page), "inactive" => (p != page),
                        "url" => page_url(request_path, p, search, sort_col, sort_dir, limit) }
        end

        if page < total_pages
          controls << { "label" => "Next", "page" => page + 1, "active" => false, "inactive" => true,
                        "url" => page_url(request_path, page + 1, search, sort_col, sort_dir, limit) }
        end
        controls
      end

      def page_url(request_path, p, search, sort_col, sort_dir, limit)
        query = "page=#{p}&search=#{URI.encode_www_form_component(search.to_s)}" \
                "&sort=#{URI.encode_www_form_component(sort_col.to_s)}" \
                "&sort_dir=#{sort_dir}&limit=#{limit}"
        h("#{request_path}?#{query}")
      end

      def sort_url(request_path, col, next_dir, page, search, limit)
        query = "sort=#{URI.encode_www_form_component(col.to_s)}&sort_dir=#{next_dir}" \
                "&page=#{page}&search=#{URI.encode_www_form_component(search.to_s)}&limit=#{limit}"
        h("#{request_path}?#{query}")
      end

      def sort_indicator(sort_col, col, sort_dir)
        return "" unless sort_col.to_s == col.to_s

        arrow = sort_dir == "asc" ? "&#9650;" : "&#9660;"
        " <span class=\"sort-indicator\">#{arrow}</span>"
      end

      # JSON config injected into the page's nonce'd <script>. The grid's whole
      # state (search/sort/sort_dir/page), the display columns, their alignment
      # and labels, and the editable columns all travel here so the client can
      # drive the AutoCrud list endpoint and re-render the table over fetch().
      # The < > & characters are unicode-escaped so the literal is safe inside
      # the <script> element.
      def js_config(api_path:, pk:, columns:, editable:, model:, limit:, search:,
                    sort_col:, sort_dir:, page:)
        aligns = {}
        labels = {}
        columns.each do |col|
          aligns[col.to_s] = column_alignment(model, col)
          labels[col.to_s] = pretty_label(col)
        end

        config = {
          "api" => api_path,
          "pk" => pk,
          "columns" => columns.map(&:to_s),
          "editable" => editable.map(&:to_s),
          "aligns" => aligns,
          "labels" => labels,
          "limit" => limit,
          "search" => search.to_s,
          "sort" => sort_col.to_s,
          "sort_dir" => sort_dir,
          "page" => page
        }
        JSON.generate(config).gsub("<", "\\u003c").gsub(">", "\\u003e").gsub("&", "\\u0026")
      end

      # Escape HTML special characters. Delegates to the framework's one
      # canonical escaper so CRUD never carries its own copy of the escape table.
      def h(text)
        Tina4::Frond.escape_html(text.to_s)
      end

      # Pretty label from a column name: "user_name" => "User Name".
      def pretty_label(col)
        col.to_s.split("_").map(&:capitalize).join(" ")
      end
    end
  end

  # Uppercase alias for convenience: Tina4::CRUD.to_crud(...)
  CRUD = Crud
end
