# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require_relative "../lib/tina4"

RSpec.describe "auto_crud flag on ORM" do
  before(:each) do
    Tina4::AutoCrud.instance_variable_set(:@models, [])
  end

  it "defaults to false" do
    klass = Class.new(Tina4::ORM) do
      table_name "widgets"
      integer_field :id, primary_key: true
    end
    expect(klass.auto_crud).to eq(false)
  end

  it "registers the model when set to true" do
    klass = Class.new(Tina4::ORM) do
      table_name "gadgets"
      integer_field :id, primary_key: true
      self.auto_crud = true
    end
    expect(Tina4::AutoCrud.models).to include(klass)
  end

  it "does not register when false" do
    klass = Class.new(Tina4::ORM) do
      table_name "things"
      integer_field :id, primary_key: true
      self.auto_crud = false
    end
    expect(Tina4::AutoCrud.models).not_to include(klass)
  end
end
