# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "json"

module Tina4
  # JSON.parse for JSON that arrives from outside the process (request bodies,
  # tokens, API responses, queue payloads), with the duplicate-key rule pinned:
  # the LAST occurrence of a repeated key wins.
  #
  # That is what Python's json.loads, PHP's json_decode and JavaScript's
  # JSON.parse do, and what the json gem did until 3.0, which raises on a
  # duplicate key by default. tina4ruby does not pin the json gem (it is a
  # default gem), so without this the same request would parse in an app that
  # resolved json 2.x and fail in one that resolved 3.x. The option is ignored
  # by json versions that predate it, which already take the last key.
  def self.parse_json(text, **options)
    JSON.parse(text, allow_duplicate_key: true, **options)
  end
end
