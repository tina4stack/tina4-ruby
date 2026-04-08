# frozen_string_literal: true

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
