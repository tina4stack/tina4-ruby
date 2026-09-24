#!/bin/bash
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

export PATH=/opt/homebrew/opt/ruby/bin:$PATH
cd /Users/andrevanzuydam/IdeaProjects/tina4-ruby
exec /opt/homebrew/opt/ruby/bin/bundle exec ruby example/app.rb
