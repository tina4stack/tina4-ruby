# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Dev file descriptor safety' do
  it 'rejects symlinks and FIFO while reading regular files' do
    Dir.mktmpdir do |dir|
      good = File.join(dir, 'good'); File.binwrite(good, 'public')
      expect(Tina4::DevAdmin.send(:read_project_bytes, good)).to eq('public')
      link = File.join(dir, 'link'); File.symlink(good, link)
      expect { Tina4::DevAdmin.send(:read_project_bytes, link) }.to raise_error(SystemCallError)
      fifo = File.join(dir, 'fifo'); File.mkfifo(fifo)
      expect { Tina4::DevAdmin.send(:read_project_bytes, fifo) }.to raise_error(ArgumentError, 'Not a regular file')
    end
  end

  it 'never follows a concurrent leaf swap' do
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'public'); File.binwrite(target, 'public')
      secret = File.join(dir, '.env'); File.binwrite(secret, 'synthetic-private')
      stop = false
      worker = Thread.new do
        next_file = File.join(dir, 'next')
        until stop
          File.symlink(secret, next_file); File.rename(next_file, target)
          File.binwrite(next_file, 'public'); File.rename(next_file, target)
        end
      end
      begin
        1000.times do
          begin
            data = Tina4::DevAdmin.send(:read_project_bytes, target)
          rescue SystemCallError
            next
          end
          expect(data).to eq('public')
        end
      ensure
        stop = true; worker.join(5)
      end
      expect(worker.alive?).to be(false)
    end
  end
end
