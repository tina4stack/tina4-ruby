# frozen_string_literal: true

module Tina4
  module Realtime
    # Channel - a conversation stream inside a workspace.
    # kind is one of public | private | dm. workspace_id is a plain integer FK
    # column (the realtime handlers query it directly; no relationship wiring
    # is needed for the control plane).
    class Channel < Tina4::ORM
      table_name "tina4_rt_channels"

      integer_field :id, primary_key: true, auto_increment: true
      integer_field :workspace_id
      string_field :name, nullable: false, length: 200
      string_field :kind, default: "public", length: 20
      datetime_field :created_at
    end
  end
end
