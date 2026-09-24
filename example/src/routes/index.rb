# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


# GET / — Welcome page rendered from a Twig template
Tina4.get "/" do |request, response|
  begin
    html = Tina4::Template.render("index.twig", {
      title: "Tina4 Ruby Example",
      message: "Welcome to Tina4 Ruby",
      version: Tina4::VERSION
    })
    response.html(html)
  rescue => e
    Tina4::Log.error("Template render failed: #{e.message}")
    response.html("<h1>Welcome to Tina4 Ruby</h1><p>Version: #{Tina4::VERSION}</p>")
  end
end
