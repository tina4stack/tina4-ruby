# frozen_string_literal: true

module Tina4
  module Crud
    class << self
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
          html += crud_javascript(table_name)
        end

        html
      end

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

      def crud_javascript(table_name)
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
end
