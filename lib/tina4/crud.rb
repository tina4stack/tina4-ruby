# frozen_string_literal: true
require "json"

module Tina4
  # Crud — Auto-generate a complete HTML CRUD interface from a SQL query or ORM model.
  #
  # Usage:
  #   Tina4.get "/admin/users" do |request, response|
  #     response.html(Tina4::Crud.to_crud(request, {
  #       sql: "SELECT id, name, email FROM users",
  #       title: "User Management",
  #       primary_key: "id"
  #     }))
  #   end
  #
  # Or with an ORM model class:
  #   Tina4.get "/admin/users" do |request, response|
  #     response.html(Tina4::Crud.to_crud(request, {
  #       model: User,
  #       title: "User Management"
  #     }))
  #   end
  module Crud
    class << self
      # Generate a complete CRUD HTML interface: searchable/paginated table
      # with create, edit, and delete modals. Also registers the supporting
      # REST API routes on first call per table.
      #
      # @param request [Tina4::Request] the current request
      # @param options [Hash] configuration options
      # @option options [String]  :sql         SQL query for listing records
      # @option options [Class]   :model       ORM model class (alternative to :sql)
      # @option options [String]  :title       page title (default: table name)
      # @option options [String]  :primary_key primary key column (default: "id")
      # @option options [String]  :prefix      API route prefix (default: "/api")
      # @option options [Integer] :limit       records per page (default: 10)
      # @return [String] complete HTML page
      def to_crud(request, options = {})
        sql        = options[:sql]
        model      = options[:model]
        title      = options[:title] || "CRUD"
        pk         = options[:primary_key] || "id"
        prefix     = options[:prefix] || "/api"
        limit      = (options[:limit] || 10).to_i

        # Determine table name and columns from SQL or model
        if model
          table_name = model.table_name.to_s
          pk = (model.primary_key_field || :id).to_s
          columns = model.field_definitions.keys.map(&:to_s)
        elsif sql
          table_name = extract_table_name(sql)
          columns = extract_columns(sql)
        else
          raise ArgumentError, "Crud.to_crud requires either :sql or :model option"
        end

        # Parse request params for pagination, search, and sorting
        query_params = request.respond_to?(:query) ? request.query : {}
        page       = [(query_params["page"] || 1).to_i, 1].max
        search     = query_params["search"].to_s.strip
        sort_col   = query_params["sort"] || pk
        sort_dir   = query_params["sort_dir"] == "desc" ? "desc" : "asc"
        offset     = (page - 1) * limit

        # Build the data query
        if model
          records, total = fetch_model_data(model, search: search, sort: sort_col,
                                            sort_dir: sort_dir, limit: limit, offset: offset)
        else
          records, total = fetch_sql_data(sql, search: search, sort: sort_col,
                                          sort_dir: sort_dir, limit: limit, offset: offset)
        end

        total_pages = total > 0 ? (total.to_f / limit).ceil : 1
        api_path = "#{prefix}/#{table_name}"

        # Register supporting CRUD API routes (idempotent)
        register_crud_routes(model, table_name, pk, prefix) unless crud_routes_registered?(table_name, prefix)

        # Build the HTML
        build_crud_html(
          title: title, table_name: table_name, pk: pk,
          columns: columns, records: records,
          page: page, total_pages: total_pages, total: total,
          limit: limit, search: search, sort_col: sort_col,
          sort_dir: sort_dir, api_path: api_path,
          request_path: request.path
        )
      end

      # Generate an HTML table from an array of record hashes.
      def generate_table(records, table_name: "data", primary_key: "id", editable: true)
        return "<p>No records found.</p>" if records.nil? || records.empty?

        columns = records.first.keys

        html = <<~HTML
          <div class="table-responsive">
          <table class="table table-striped table-hover" id="crud-#{table_name}">
          <thead class="table-dark"><tr>
        HTML

        columns.each do |col|
          html += "<th>#{col}</th>"
        end
        html += "<th>Actions</th>" if editable
        html += "</tr></thead><tbody>"

        records.each do |row|
          pk_value = row[primary_key.to_sym] || row[primary_key.to_s]
          html += "<tr data-id=\"#{pk_value}\">"
          columns.each do |col|
            value = row[col]
            if editable
              html += "<td contenteditable=\"true\" data-field=\"#{col}\">#{value}</td>"
            else
              html += "<td>#{value}</td>"
            end
          end
          if editable
            html += "<td>"
            html += "<button class=\"btn btn-sm btn-primary me-1\" onclick=\"crudSave('#{table_name}', '#{pk_value}')\">Save</button>"
            html += "<button class=\"btn btn-sm btn-danger\" onclick=\"crudDelete('#{table_name}', '#{pk_value}')\">Delete</button>"
            html += "</td>"
          end
          html += "</tr>"
        end

        html += "</tbody></table></div>"

        if editable
          html += inline_crud_javascript(table_name)
        end

        html
      end

      # Generate an HTML form from a field definition array.
      def generate_form(fields, action: "/", method: "POST", table_name: "data")
        html = "<form action=\"#{action}\" method=\"#{method}\" class=\"needs-validation\" novalidate>"
        html += "<input type=\"hidden\" name=\"_method\" value=\"#{method}\">" if %w[PUT PATCH DELETE].include?(method.upcase)

        fields.each do |field|
          name = field[:name]
          type = field[:type] || :string
          label = field[:label] || name.to_s.capitalize
          value = field[:value] || ""
          required = field[:required] || false

          html += "<div class=\"mb-3\">"
          html += "<label for=\"#{name}\" class=\"form-label\">#{label}</label>"

          case type.to_sym
          when :text
            html += "<textarea class=\"form-control\" id=\"#{name}\" name=\"#{name}\" #{'required' if required}>#{value}</textarea>"
          when :boolean
            checked = value ? "checked" : ""
            html += "<div class=\"form-check\">"
            html += "<input class=\"form-check-input\" type=\"checkbox\" id=\"#{name}\" name=\"#{name}\" #{checked}>"
            html += "</div>"
          when :select
            html += "<select class=\"form-select\" id=\"#{name}\" name=\"#{name}\" #{'required' if required}>"
            (field[:options] || []).each do |opt|
              selected = opt[:value].to_s == value.to_s ? "selected" : ""
              html += "<option value=\"#{opt[:value]}\" #{selected}>#{opt[:label]}</option>"
            end
            html += "</select>"
          when :date
            html += "<input type=\"date\" class=\"form-control\" id=\"#{name}\" name=\"#{name}\" value=\"#{value}\" #{'required' if required}>"
          when :integer, :number
            html += "<input type=\"number\" class=\"form-control\" id=\"#{name}\" name=\"#{name}\" value=\"#{value}\" #{'required' if required}>"
          else
            html += "<input type=\"text\" class=\"form-control\" id=\"#{name}\" name=\"#{name}\" value=\"#{value}\" #{'required' if required}>"
          end
          html += "</div>"
        end

        html += "<button type=\"submit\" class=\"btn btn-primary\">Submit</button>"
        html += "</form>"
        html
      end

      private

      # Track which tables have had CRUD routes registered
      def registered_tables
        @registered_tables ||= {}
      end

      def crud_routes_registered?(table_name, prefix)
        registered_tables["#{prefix}/#{table_name}"]
      end

      # Register REST API routes for the CRUD interface when using :sql mode.
      # When using :model mode, the caller should use AutoCrud.register instead
      # for full ORM-backed routes. These routes provide basic SQL-backed CRUD.
      def register_crud_routes(model, table_name, pk, prefix)
        api_path = "#{prefix}/#{table_name}"
        registered_tables[api_path] = true

        # If we have a model, use AutoCrud for full ORM-backed routes
        if model
          Tina4::AutoCrud.register(model)
          Tina4::AutoCrud.generate_routes(prefix: prefix)
          return
        end

        db = Tina4.database
        return unless db

        # GET list (already handled by the page itself)
        # POST create
        Tina4::Router.add("POST", api_path, proc { |req, res|
          begin
            data = req.body_parsed
            result = db.insert(table_name, data)
            res.json({ data: data, message: "Created" }, status: 201)
          rescue => e
            res.json({ error: e.message }, status: 500)
          end
        })

        # PUT update
        Tina4::Router.add("PUT", "#{api_path}/{id}", proc { |req, res|
          begin
            id = req.params["id"]
            data = req.body_parsed
            db.update(table_name, data, { pk => id })
            res.json({ data: data, message: "Updated" })
          rescue => e
            res.json({ error: e.message }, status: 500)
          end
        })

        # DELETE
        Tina4::Router.add("DELETE", "#{api_path}/{id}", proc { |req, res|
          begin
            id = req.params["id"]
            db.delete(table_name, { pk => id })
            res.json({ message: "Deleted" })
          rescue => e
            res.json({ error: e.message }, status: 500)
          end
        })
      end

      # Fetch data using an ORM model class
      def fetch_model_data(model, search: "", sort: "id", sort_dir: "asc", limit: 10, offset: 0)
        order_by = "#{sort} #{sort_dir.upcase}"

        if search.empty?
          records = model.all(limit: limit, offset: offset, order_by: order_by)
          total = model.count
        else
          # Build search across all string/text fields
          searchable = model.field_definitions.select { |_, opts|
            [:string, :text].include?(opts[:type])
          }.keys
          if searchable.empty?
            records = model.all(limit: limit, offset: offset, order_by: order_by)
            total = model.count
          else
            where_parts = searchable.map { |col| "#{col} LIKE ?" }
            where_clause = where_parts.join(" OR ")
            params = searchable.map { "%#{search}%" }
            records = model.where(where_clause, params)
            total = records.length
            records = records.slice(offset, limit) || []
          end
        end

        record_hashes = records.map { |r| r.to_h }
        [record_hashes, total]
      end

      # Fetch data using a raw SQL query
      def fetch_sql_data(sql, search: "", sort: "id", sort_dir: "asc", limit: 10, offset: 0)
        db = Tina4.database
        return [[], 0] unless db

        # Wrap the original SQL for sorting
        query = sql.gsub(/ORDER BY .+$/i, "").gsub(/LIMIT .+$/i, "").strip
        query += " ORDER BY #{sort} #{sort_dir.upcase}"

        if !search.empty?
          # Wrap in a subquery to add search filtering
          wrapped = "SELECT * FROM (#{sql.gsub(/ORDER BY .+$/i, '').gsub(/LIMIT .+$/i, '').strip}) AS _crud_sub WHERE "
          columns = extract_columns(sql)
          search_parts = columns.map { |col| "CAST(#{col} AS TEXT) LIKE ?" }
          wrapped += search_parts.join(" OR ")
          wrapped += " ORDER BY #{sort} #{sort_dir.upcase}"
          params = columns.map { "%#{search}%" }

          # Get total count
          count_sql = "SELECT COUNT(*) as cnt FROM (#{sql.gsub(/ORDER BY .+$/i, '').gsub(/LIMIT .+$/i, '').strip}) AS _crud_cnt WHERE #{search_parts.join(' OR ')}"
          count_result = db.fetch_one(count_sql, params)
          total = count_result ? (count_result[:cnt] || count_result["cnt"] || 0).to_i : 0

          results = db.fetch(wrapped, params, limit: limit, offset: offset)
        else
          # Get total count
          count_sql = "SELECT COUNT(*) as cnt FROM (#{sql.gsub(/ORDER BY .+$/i, '').gsub(/LIMIT .+$/i, '').strip}) AS _crud_cnt"
          count_result = db.fetch_one(count_sql)
          total = count_result ? (count_result[:cnt] || count_result["cnt"] || 0).to_i : 0

          results = db.fetch(query, [], limit: limit, offset: offset)
        end

        records = results.respond_to?(:records) ? results.records : results.to_a
        [records, total]
      end

      # Extract table name from a SQL SELECT statement
      def extract_table_name(sql)
        match = sql.match(/FROM\s+(\w+)/i)
        match ? match[1] : "data"
      end

      # Extract column names from a SQL SELECT statement
      def extract_columns(sql)
        match = sql.match(/SELECT\s+(.+?)\s+FROM/im)
        return ["*"] unless match

        cols_str = match[1].strip
        return ["*"] if cols_str == "*"

        cols_str.split(",").map { |c|
          c = c.strip
          # Handle "table.column AS alias" or "column AS alias"
          if c =~ /\bAS\s+(\w+)/i
            $1
          elsif c.include?(".")
            c.split(".").last.strip
          else
            c.strip
          end
        }
      end

      # Escape HTML special characters
      def h(text)
        text.to_s
          .gsub("&", "&amp;")
          .gsub("<", "&lt;")
          .gsub(">", "&gt;")
          .gsub('"', "&quot;")
          .gsub("'", "&#39;")
      end

      # Pretty label from a column name: "user_name" => "User Name"
      def pretty_label(col)
        col.to_s.split("_").map(&:capitalize).join(" ")
      end

      # Determine input type from column name or ORM field type
      def input_type_for(col, model = nil)
        if model && model.respond_to?(:field_definitions)
          opts = model.field_definitions[col.to_sym]
          if opts
            case opts[:type]
            when :integer             then return "number"
            when :float, :decimal     then return "number"
            when :boolean             then return "checkbox"
            when :date                then return "date"
            when :datetime, :timestamp then return "datetime-local"
            when :text                then return "textarea"
            end
          end
        end
        # Guess from column name
        return "email" if col.to_s.include?("email")
        return "date"  if col.to_s.end_with?("_at", "_date")
        return "number" if col.to_s.end_with?("_id") && col.to_s != "id"
        "text"
      end

      # Build the complete CRUD HTML page
      def build_crud_html(title:, table_name:, pk:, columns:, records:,
                          page:, total_pages:, total:, limit:, search:,
                          sort_col:, sort_dir:, api_path:, request_path:)
        # Filter out auto-increment PK from editable columns
        editable_columns = columns.reject { |c| c.to_s == pk.to_s }

        html = <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>#{h(title)}</title>
          <link rel="stylesheet" href="/css/tina4.min.css">
          <style>
          .crud-container { max-width: 1200px; margin: 2rem auto; padding: 0 1rem; }
          .crud-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; }
          .crud-search { max-width: 300px; }
          .crud-actions { display: flex; gap: 0.5rem; align-items: center; }
          .crud-info { color: var(--text-muted, #6c757d); font-size: 0.875rem; margin-bottom: 0.5rem; }
          .crud-pagination { display: flex; justify-content: center; gap: 0.25rem; margin-top: 1rem; }
          .sort-link { text-decoration: none; color: inherit; cursor: pointer; }
          .sort-link:hover { text-decoration: underline; }
          .sort-indicator { font-size: 0.75rem; }
          .modal-overlay { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%;
            background: rgba(0,0,0,0.5); z-index: 1000; justify-content: center; align-items: center; }
          .modal-overlay.active { display: flex; }
          .modal-box { background: var(--bg, #fff); border-radius: 0.5rem; padding: 1.5rem;
            width: 90%; max-width: 600px; max-height: 80vh; overflow-y: auto;
            box-shadow: 0 4px 20px rgba(0,0,0,0.3); }
          .modal-box h3 { margin-top: 0; }
          .modal-footer { display: flex; justify-content: flex-end; gap: 0.5rem; margin-top: 1rem; }
          .alert { padding: 0.75rem 1rem; border-radius: 0.25rem; margin-bottom: 1rem; display: none; }
          .alert-success { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
          .alert-danger { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
          </style>
          </head>
          <body>
          <div class="crud-container">
            <div id="crud-alert" class="alert"></div>
            <div class="crud-header">
              <h2>#{h(title)}</h2>
              <div class="crud-actions">
                <form method="GET" action="#{h(request_path)}" style="display:flex;gap:0.5rem;">
                  <input type="text" name="search" value="#{h(search)}" placeholder="Search..."
                    class="form-control crud-search">
                  <button type="submit" class="btn btn-secondary">Search</button>
                </form>
                <button class="btn btn-primary" onclick="crudShowCreate()">+ New</button>
              </div>
            </div>
            <div class="crud-info">
              Showing #{records.length} of #{total} records (page #{page} of #{total_pages})
            </div>
            <div class="table-responsive">
            <table class="table table-striped table-hover">
            <thead class="table-dark"><tr>
        HTML

        # Table headers with sort links
        columns.each do |col|
          next_dir = (sort_col == col.to_s && sort_dir == "asc") ? "desc" : "asc"
          indicator = ""
          if sort_col == col.to_s
            indicator = sort_dir == "asc" ? " <span class=\"sort-indicator\">&#9650;</span>" : " <span class=\"sort-indicator\">&#9660;</span>"
          end
          sort_params = "sort=#{h(col)}&sort_dir=#{next_dir}&page=#{page}&search=#{URI.encode_www_form_component(search)}&limit=#{limit}"
          html += "<th><a class=\"sort-link\" href=\"#{h(request_path)}?#{sort_params}\">#{pretty_label(col)}#{indicator}</a></th>"
        end
        html += "<th>Actions</th></tr></thead><tbody>"

        # Table body
        if records.empty?
          html += "<tr><td colspan=\"#{columns.length + 1}\" style=\"text-align:center;padding:2rem;\">No records found.</td></tr>"
        else
          records.each do |row|
            pk_value = row[pk.to_sym] || row[pk.to_s] || row[pk]
            html += "<tr>"
            columns.each do |col|
              value = row[col.to_sym] || row[col.to_s] || row[col]
              html += "<td>#{h(value)}</td>"
            end
            html += "<td>"
            html += "<button class=\"btn btn-sm btn-primary me-1\" onclick=\"crudShowEdit(#{pk_value.is_a?(String) ? "'#{h(pk_value)}'" : pk_value})\">Edit</button>"
            html += "<button class=\"btn btn-sm btn-danger\" onclick=\"crudShowDelete(#{pk_value.is_a?(String) ? "'#{h(pk_value)}'" : pk_value})\">Delete</button>"
            html += "</td></tr>"
          end
        end
        html += "</tbody></table></div>"

        # Pagination
        if total_pages > 1
          html += "<div class=\"crud-pagination\">"
          if page > 1
            html += "<a class=\"btn btn-sm btn-secondary\" href=\"#{h(request_path)}?page=#{page - 1}&search=#{URI.encode_www_form_component(search)}&sort=#{h(sort_col)}&sort_dir=#{h(sort_dir)}&limit=#{limit}\">Prev</a>"
          end
          # Show page numbers (max 7)
          start_page = [page - 3, 1].max
          end_page = [start_page + 6, total_pages].min
          start_page = [end_page - 6, 1].max
          (start_page..end_page).each do |p|
            active = p == page ? " btn-primary" : " btn-secondary"
            html += "<a class=\"btn btn-sm#{active}\" href=\"#{h(request_path)}?page=#{p}&search=#{URI.encode_www_form_component(search)}&sort=#{h(sort_col)}&sort_dir=#{h(sort_dir)}&limit=#{limit}\">#{p}</a>"
          end
          if page < total_pages
            html += "<a class=\"btn btn-sm btn-secondary\" href=\"#{h(request_path)}?page=#{page + 1}&search=#{URI.encode_www_form_component(search)}&sort=#{h(sort_col)}&sort_dir=#{h(sort_dir)}&limit=#{limit}\">Next</a>"
          end
          html += "</div>"
        end

        # Create modal
        html += build_modal("create", "Create New Record", editable_columns, pk, api_path, request_path)

        # Edit modal
        html += build_modal("edit", "Edit Record", editable_columns, pk, api_path, request_path, edit: true)

        # Delete confirmation modal
        html += <<~HTML
          <div class="modal-overlay" id="modal-delete">
            <div class="modal-box">
              <h3>Confirm Delete</h3>
              <p>Are you sure you want to delete this record? This action cannot be undone.</p>
              <input type="hidden" id="delete-pk-value">
              <div class="modal-footer">
                <button class="btn btn-secondary" onclick="crudCloseModal('delete')">Cancel</button>
                <button class="btn btn-danger" onclick="crudConfirmDelete()">Delete</button>
              </div>
            </div>
          </div>
        HTML

        # JavaScript
        html += build_crud_javascript(api_path, pk, editable_columns, request_path)

        html += "</div></body></html>"
        html
      end

      # Build a create or edit modal
      def build_modal(id, title, columns, pk, api_path, request_path, edit: false)
        html = "<div class=\"modal-overlay\" id=\"modal-#{id}\">"
        html += "<div class=\"modal-box\">"
        html += "<h3>#{h(title)}</h3>"
        html += "<form id=\"form-#{id}\" onsubmit=\"return false;\">"
        html += "<input type=\"hidden\" id=\"#{id}-pk-value\" name=\"#{pk}\">" if edit

        columns.each do |col|
          label = pretty_label(col)
          field_id = "#{id}-#{col}"
          html += "<div class=\"mb-3\">"
          html += "<label for=\"#{field_id}\" class=\"form-label\">#{label}</label>"
          html += "<input type=\"text\" class=\"form-control\" id=\"#{field_id}\" name=\"#{col}\" placeholder=\"Enter #{label.downcase}\">"
          html += "</div>"
        end

        html += "<div class=\"modal-footer\">"
        html += "<button type=\"button\" class=\"btn btn-secondary\" onclick=\"crudCloseModal('#{id}')\">Cancel</button>"
        html += "<button type=\"button\" class=\"btn btn-primary\" onclick=\"crudSave#{edit ? 'Edit' : 'Create'}()\">Save</button>"
        html += "</div></form></div></div>"
        html
      end

      # Build the JavaScript for the CRUD interface
      def build_crud_javascript(api_path, pk, columns, request_path)
        columns_json = JSON.generate(columns.map(&:to_s))
        <<~HTML
          <script>
          var CRUD_API = '#{api_path}';
          var CRUD_PK = '#{pk}';
          var CRUD_COLUMNS = #{columns_json};

          function crudShowAlert(message, type) {
            var el = document.getElementById('crud-alert');
            el.className = 'alert alert-' + type;
            el.textContent = message;
            el.style.display = 'block';
            setTimeout(function() { el.style.display = 'none'; }, 3000);
          }

          function crudShowCreate() {
            var form = document.getElementById('form-create');
            form.reset();
            document.getElementById('modal-create').classList.add('active');
          }

          function crudShowEdit(id) {
            fetch(CRUD_API + '/' + id)
              .then(function(r) { return r.json(); })
              .then(function(result) {
                var data = result.data || result;
                document.getElementById('edit-pk-value').value = id;
                CRUD_COLUMNS.forEach(function(col) {
                  var input = document.getElementById('edit-' + col);
                  if (input) input.value = data[col] != null ? data[col] : '';
                });
                document.getElementById('modal-edit').classList.add('active');
              })
              .catch(function(e) { crudShowAlert('Failed to load record: ' + e, 'danger'); });
          }

          function crudShowDelete(id) {
            document.getElementById('delete-pk-value').value = id;
            document.getElementById('modal-delete').classList.add('active');
          }

          function crudCloseModal(name) {
            document.getElementById('modal-' + name).classList.remove('active');
          }

          function crudSaveCreate() {
            var data = {};
            CRUD_COLUMNS.forEach(function(col) {
              var input = document.getElementById('create-' + col);
              if (input) data[col] = input.value;
            });
            fetch(CRUD_API, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(data)
            })
            .then(function(r) { return r.json(); })
            .then(function(result) {
              if (result.error) { crudShowAlert(result.error, 'danger'); return; }
              crudCloseModal('create');
              crudShowAlert('Record created successfully', 'success');
              setTimeout(function() { window.location.reload(); }, 500);
            })
            .catch(function(e) { crudShowAlert('Failed to create: ' + e, 'danger'); });
          }

          function crudSaveEdit() {
            var id = document.getElementById('edit-pk-value').value;
            var data = {};
            CRUD_COLUMNS.forEach(function(col) {
              var input = document.getElementById('edit-' + col);
              if (input) data[col] = input.value;
            });
            fetch(CRUD_API + '/' + id, {
              method: 'PUT',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(data)
            })
            .then(function(r) { return r.json(); })
            .then(function(result) {
              if (result.error) { crudShowAlert(result.error, 'danger'); return; }
              crudCloseModal('edit');
              crudShowAlert('Record updated successfully', 'success');
              setTimeout(function() { window.location.reload(); }, 500);
            })
            .catch(function(e) { crudShowAlert('Failed to update: ' + e, 'danger'); });
          }

          function crudConfirmDelete() {
            var id = document.getElementById('delete-pk-value').value;
            fetch(CRUD_API + '/' + id, { method: 'DELETE' })
            .then(function(r) { return r.json(); })
            .then(function(result) {
              if (result.error) { crudShowAlert(result.error, 'danger'); return; }
              crudCloseModal('delete');
              crudShowAlert('Record deleted successfully', 'success');
              setTimeout(function() { window.location.reload(); }, 500);
            })
            .catch(function(e) { crudShowAlert('Failed to delete: ' + e, 'danger'); });
          }

          // Close modal on overlay click
          document.querySelectorAll('.modal-overlay').forEach(function(overlay) {
            overlay.addEventListener('click', function(e) {
              if (e.target === overlay) overlay.classList.remove('active');
            });
          });

          // Close modal on Escape key
          document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') {
              document.querySelectorAll('.modal-overlay.active').forEach(function(m) {
                m.classList.remove('active');
              });
            }
          });
          </script>
        HTML
      end

      def inline_crud_javascript(table_name)
        <<~JS
          <script>
          function crudSave(table, id) {
            const row = document.querySelector(`tr[data-id="${id}"]`);
            const cells = row.querySelectorAll('td[data-field]');
            const data = {};
            cells.forEach(cell => { data[cell.dataset.field] = cell.textContent; });
            fetch(`/api/${table}/${id}`, {
              method: 'PUT',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(data)
            }).then(r => r.json()).then(d => { alert('Saved!'); }).catch(e => alert('Error: ' + e));
          }
          function crudDelete(table, id) {
            if (!confirm('Delete this record?')) return;
            fetch(`/api/${table}/${id}`, { method: 'DELETE' })
              .then(r => r.json())
              .then(d => { document.querySelector(`tr[data-id="${id}"]`).remove(); })
              .catch(e => alert('Error: ' + e));
          }
          </script>
        JS
      end
    end
  end

  # Uppercase alias for convenience: Tina4::CRUD.to_crud(...)
  CRUD = Crud
end
