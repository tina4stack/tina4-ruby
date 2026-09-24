# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


module Tina4
  module Realtime
    # Attachment - a file linked to a channel (and optionally a message).
    # channel_id scopes the file for permission checks; message_id is nil until
    # the file is attached to a posted message. storage_key is the StorageBackend
    # key; the row carries only metadata, never the blob.
    class Attachment < Tina4::ORM
      table_name "tina4_rt_attachments"

      integer_field :id, primary_key: true, auto_increment: true
      integer_field :channel_id
      integer_field :message_id
      string_field :storage_key, nullable: false, length: 255
      string_field :filename, length: 255
      string_field :mime, length: 128
      integer_field :size
      string_field :thumb_key, length: 255
    end
  end
end
