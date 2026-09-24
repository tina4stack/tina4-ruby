# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


module Tina4
  module Realtime
    # Blob store interface for the realtime "files" feature.
    #
    # put writes bytes, get reads them back, url returns a directly fetchable
    # URL when the backend supports one (else nil - serve via the app download
    # route), delete removes, exists? checks presence.
    class StorageBackend
      def put(_key, _data, _mime = "application/octet-stream")
        raise NotImplementedError
      end

      def get(_key)
        raise NotImplementedError
      end

      def url(_key, _ttl = 3600)
        nil
      end

      def delete(_key)
        raise NotImplementedError
      end

      def exists?(_key)
        raise NotImplementedError
      end
    end
  end
end
