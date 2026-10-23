# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "securerandom"

module Tina4
  # Per-response Content-Security-Policy nonce (ADR-0088).
  #
  # The framework serves a strict default CSP (`default-src 'self'`). A browser
  # refuses every inline `<style>` and `<script>` under that policy unless the
  # element carries a nonce that the `Content-Security-Policy` header also names.
  # So the framework mints one cryptographically-random nonce per response, stamps
  # it on every inline `<style>`/`<script>` it emits, and injects the matching
  # `'nonce-<X>'` into the `style-src` and `script-src` directives of the CSP
  # header. The same value reaches user templates through the Frond global
  # `csp_nonce()`.
  #
  # The nonce lives in a thread-local, so each request (one Puma worker thread)
  # gets its own value and concurrent requests never see each other's.
  # `RackApp#call` sets a fresh nonce at the start of every request and clears it
  # in `ensure`, exactly as it does the request id. Whoever touches the nonce
  # first in a request — the body emitter rendering inline content, or the
  # security middleware building the header — gets the same value, because
  # {current_nonce} generates one on first access and caches it on the thread for
  # the rest of the request.
  module Csp
    THREAD_KEY = :tina4_csp_nonce

    module_function

    # Return a fresh cryptographically-random nonce (128 bits, base64).
    # SecureRandom.base64 is stdlib (no `base64` gem), encodes 16 random bytes.
    def generate_nonce
      SecureRandom.base64(16)
    end

    # Set the nonce for the current request (thread) context.
    def set_current_nonce(value)
      Thread.current[THREAD_KEY] = value
    end

    # Clear the nonce at the end of a request (mirrors Log.clear_request_id).
    def clear_current_nonce
      Thread.current[THREAD_KEY] = nil
    end

    # Return the current request's nonce, minting one on first access.
    #
    # Generate-on-first-access makes the value independent of ordering: whether
    # the inline body or the CSP header is built first, both read the same nonce.
    def current_nonce
      value = Thread.current[THREAD_KEY]
      if value.nil? || value.empty?
        value = generate_nonce
        Thread.current[THREAD_KEY] = value
      end
      value
    end

    # Frond / template global: the current response's CSP nonce.
    #
    #   <style nonce="{{ csp_nonce() }}"> ... </style>
    #   <script nonce="{{ csp_nonce() }}"> ... </script>
    def csp_nonce
      current_nonce
    end

    # Return +csp+ with `'nonce-<nonce>'` present in style-src AND script-src.
    #
    # For the default `default-src 'self'` this yields
    # `default-src 'self'; style-src 'self' 'nonce-X'; script-src 'self' 'nonce-X'`.
    # When a directive is absent it is derived from `default-src` (falling back to
    # `'self'`) so the framework's own nonce'd content always works; when present
    # the nonce is appended (idempotently). Every other directive is kept, in order.
    def inject_nonce_into_csp(csp, nonce)
      token = "'nonce-#{nonce}'"
      directives = []
      csp.to_s.split(";").each do |part|
        part = part.strip
        next if part.empty?

        bits = part.split(/\s+/, 2)
        name = bits[0].downcase
        value = bits.length > 1 ? bits[1].strip : ""
        directives << [name, value]
      end

      default_pair = directives.find { |name, _| name == "default-src" }
      default_value = default_pair ? default_pair[1] : "'self'"

      %w[style-src script-src].each do |directive|
        existing = directives.find { |name, _| name == directive }
        if existing
          # ADR-0100: the app opted this directive into inline via
          # 'unsafe-inline'. A browser ignores 'unsafe-inline' the moment a
          # nonce joins the same directive (CSP Level 2+), so adding the nonce
          # would silently block the inline the app asked for. The app wins.
          next if existing[1].split(/\s+/).include?("'unsafe-inline'")

          existing[1] = "#{existing[1]} #{token}".strip unless existing[1].split(/\s+/).include?(token)
        else
          base = default_value.empty? ? "'self'" : default_value
          # ADR-0100: a directive derived from an 'unsafe-inline' default-src
          # must not be spawned with a nonce - it would cancel the inline the
          # app allowed through default-src.
          next if base.split(/\s+/).include?("'unsafe-inline'")

          directives << [directive, "#{base} #{token}".strip]
        end
      end

      directives.map { |name, value| value.empty? ? name : "#{name} #{value}" }.join("; ")
    end

    # Build the CSP header value for +nonce+ from the environment.
    #
    # Honours TINA4_CSP (default `default-src 'self'`) and always injects the
    # nonce into style-src and script-src. A blank TINA4_CSP is treated as the
    # default policy (the empty-string / unset behaviour is unchanged elsewhere).
    def resolve_csp_header(nonce)
      csp = ENV["TINA4_CSP"]
      csp = "default-src 'self'" if csp.nil? || csp.empty?
      inject_nonce_into_csp(csp, nonce)
    end
  end
end
