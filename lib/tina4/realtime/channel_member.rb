# frozen_string_literal: true

module Tina4
  module Realtime
    # ChannelMember - a user's membership of a channel plus their read cursor.
    # user_id is a string so it holds any identity shape the app puts in the JWT
    # (an integer id, a UUID, an email). last_read_at is the read-receipt cursor.
    class ChannelMember < Tina4::ORM
      table_name "tina4_rt_channel_members"

      integer_field :id, primary_key: true, auto_increment: true
      integer_field :channel_id
      string_field :user_id, nullable: false, length: 128
      string_field :role, default: "member", length: 20
      datetime_field :last_read_at
    end
  end
end
