class Todo < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  integer_field :completed, default: 0
  datetime_field :created_at
end
