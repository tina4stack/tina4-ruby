# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"

# The CRUD HTML component is CSP-clean under the strict default policy
# (ADR-0088). The framework serves default-src 'self'. A CSP nonce authorises a
# <script>/<style> ELEMENT but NEVER an inline on*= event-handler attribute, so
# a button that wires its action with onclick="..." (or a form with onsubmit)
# is dead under the policy. Tina4::Crud must therefore emit ZERO inline on*=
# attributes and bind every action with addEventListener inside its nonce'd
# <script>.
#
# NO MOCKS: a real SQLite database on disk, a real Tina4::Request, and the real
# Tina4::Crud HTML generator. The assertions run against the exact bytes the
# framework emits.

class CrudCspModel < Tina4::ORM
  table_name "crudcspmodels"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false
  string_field :email
end

RSpec.describe "Tina4::Crud CSP (no inline on*= handlers)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_crud_csp") }
  let(:db_path) { File.join(tmp_dir, "crud_csp.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  # Matches an inline HTML event-handler attribute (onclick=, onsubmit=, …) but
  # NOT a JS property assignment (el.onclick = fn), which is CSP-allowed.
  INLINE_HANDLER_ATTR = /\son[a-z]+\s*=\s*["']/.freeze
  # Matches an inline style= attribute — dead under default-src 'self' (ADR-0088).
  INLINE_STYLE_ATTR = /\sstyle\s*=\s*["']/.freeze

  before(:each) do
    Tina4.bind_database(db)
    Tina4::Router.clear!
    Tina4::AutoCrud.clear!
    Tina4::Crud.instance_variable_set(:@registered_tables, {})
    db.execute("CREATE TABLE IF NOT EXISTS crudcspmodels (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT)")
    db.insert("crudcspmodels", { name: "Alice", email: "alice@example.com" })
    db.insert("crudcspmodels", { name: "Bob", email: "bob@example.com" })
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  def request(path: "/admin/crudcspmodels", query: {})
    Tina4::Request.new(
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => path,
      "QUERY_STRING" => query.map { |k, v| "#{k}=#{v}" }.join("&"),
      "CONTENT_TYPE" => "text/html"
    )
  end

  describe "to_crud full page" do
    let(:html) { Tina4::Crud.to_crud(request, { model: CrudCspModel, title: "CSP CRUD" }) }

    it "emits the records and modals" do
      expect(html).to include("Alice")
      expect(html).to include("Bob")
      expect(html).to include("modal-create")
    end

    it "has ZERO inline on*= event-handler attributes" do
      offenders = html.scan(INLINE_HANDLER_ATTR)
      expect(offenders).to eq([]), "inline on*= attribute(s) emitted: #{offenders.inspect}"
    end

    it "has ZERO inline style= attributes" do
      offenders = html.scan(INLINE_STYLE_ATTR)
      expect(offenders).to eq([]), "inline style= attribute(s) emitted: #{offenders.inspect}"
    end

    it "the on*= / style= gates are real — they catch an injected attribute (mutation proof)" do
      # Prove the regexes are genuine gates: a page carrying the forbidden
      # attributes MUST be flagged. A gate never seen to fail is not known to
      # work.
      mutated = html.sub("<h2>", '<h2 onclick="x()" style="color:red">')
      expect(mutated.scan(INLINE_HANDLER_ATTR)).not_to eq([])
      expect(mutated.scan(INLINE_STYLE_ATTR)).not_to eq([])
    end

    it "registers the full AutoCrud REST backend, including GET list + GET/{id}" do
      html # trigger the render (registers routes as a side effect)
      routes = Tina4::Router.routes.map { |r| "#{r.method} #{r.path}" }
      expect(routes).to include("GET /api/crudcspmodels")
      expect(routes).to include("GET /api/crudcspmodels/{id}")
      expect(routes).to include("POST /api/crudcspmodels")
      expect(routes).to include("PUT /api/crudcspmodels/{id}")
      expect(routes).to include("DELETE /api/crudcspmodels/{id}")
    end

    it "wires the create/edit/delete buttons with data-crud-action" do
      expect(html).to include('data-crud-action="create"')
      expect(html).to include('data-crud-action="edit"')
      expect(html).to include('data-crud-action="delete"')
      expect(html).to include('data-crud-action="save"')
      expect(html).to include('data-crud-action="confirm-delete"')
      expect(html).to include('data-id="')            # row id rides in data-id
      expect(html).to include('data-crud-mode="')      # save knows create vs edit
    end

    it "binds those actions through a delegated listener in a nonce'd <script>" do
      expect(html).to include("<script nonce=")
      expect(html).to include("addEventListener('click'")
      expect(html).to include("data-crud-action")
      expect(html).to include("button.dataset.crudAction")
      # the modal form's native submit is stopped by a listener, not onsubmit=
      expect(html).to include("addEventListener('submit'")
      expect(html).to include('data-crud-form="1"')
    end
  end

  describe "generate_table inline-edit fragment" do
    let(:records) do
      [
        { id: 1, name: "Alice's \"Gadget\"", email: "alice@example.com" },
        { id: 2, name: "Bob", email: "bob@example.com" }
      ]
    end
    let(:html) { Tina4::Crud.generate_table(records, table_name: "crudcspmodels", primary_key: "id") }

    it "has ZERO inline on*= event-handler attributes" do
      offenders = html.scan(INLINE_HANDLER_ATTR)
      expect(offenders).to eq([]), "inline on*= attribute(s) emitted: #{offenders.inspect}"
    end

    it "has ZERO inline style= attributes" do
      offenders = html.scan(INLINE_STYLE_ATTR)
      expect(offenders).to eq([]), "inline style= attribute(s) emitted: #{offenders.inspect}"
    end

    it "wires Save/Delete with data-crud-inline + a delegated listener" do
      expect(html).to include('data-crud-inline="save"')
      expect(html).to include('data-crud-inline="delete"')
      expect(html).to include('data-table="crudcspmodels"')
      expect(html).to include("<script nonce=")
      expect(html).to include("addEventListener('click'")
      expect(html).to include("button.dataset.crudInline")
    end
  end

  # ADR-0094: every crud/ template is app-overridable via the existing
  # app-first-then-gem resolution (Tina4::Template). Dropping
  # templates/crud/table.twig in the app's working directory MUST win over the
  # gem's shipped template.
  describe "app template override" do
    it "uses an app templates/crud/table.twig instead of the gem's" do
      project = Dir.mktmpdir("tina4_crud_override")
      FileUtils.mkdir_p(File.join(project, "templates", "crud"))
      File.write(
        File.join(project, "templates", "crud", "table.twig"),
        "<div class=\"app-override-marker\">OVERRIDDEN TABLE</div>"
      )

      html = Dir.chdir(project) do
        Tina4::Crud.to_crud(request, { model: CrudCspModel, title: "Override" })
      end

      expect(html).to include("app-override-marker")
      expect(html).to include("OVERRIDDEN TABLE")
      # The page shell (not overridden) still rendered around it.
      expect(html).to include("Override")
      expect(html).to include("modal-create")
    ensure
      FileUtils.rm_rf(project) if project
    end
  end
end
