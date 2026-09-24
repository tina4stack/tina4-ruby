# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

module Tina4
  # Internal credential persistence: validate and read/write the same descriptor.
  module SecretFile
    def self.update(path)
      begin
        before = File.lstat(path)
        raise IOError, "credential target must be an unlinked regular file" unless before.file? && before.nlink == 1
      rescue Errno::ENOENT
        # The O_CREAT open below creates the file with owner-only permissions.
      end
      flags = File::RDWR | File::CREAT
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      flags |= File::NONBLOCK if defined?(File::NONBLOCK)
      File.open(path, flags, 0o600) do |file|
        file.flock(File::LOCK_EX)
        stat = file.stat
        raise IOError, "credential target must be an unlinked regular file" unless stat.file? && stat.nlink == 1
        file.chmod(0o600)
        content = yield file.read
        file.rewind
        file.truncate(0)
        file.write(content)
        file.flush
      end
    end
  end
end
