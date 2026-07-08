# frozen_string_literal: true

module Tina4
  module Realtime
    # Message - one posted message in a channel.
    # thread_id is nil for a top-level message, or the id of the parent message
    # for a threaded reply. edited_at is nil until an edit.
    class Message < Tina4::ORM
      table_name "tina4_rt_messages"

      integer_field :id, primary_key: true, auto_increment: true
      integer_field :channel_id
      string_field :user_id, nullable: false, length: 128
      text_field :body
      integer_field :thread_id
      datetime_field :created_at
      datetime_field :edited_at
    end
  end
end
