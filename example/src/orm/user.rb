# frozen_string_literal: true

class User < Tina4::ORM
  table_name "users"
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :first_name
  string_field  :last_name
  string_field  :email
  integer_field :age, nullable: true
end
