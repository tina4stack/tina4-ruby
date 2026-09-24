# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "ipaddr"
require "resolv"
require "socket"
require "uri"

module Tina4
  # Raised when the SSRF guard refuses an outbound request.
  class SsrfError < StandardError; end

  # Outbound SSRF guard (ADR-0084).
  #
  # The Api client and Web Push refuse, by default, to connect to a private or
  # internal address. Before each connection - the initial URL and every redirect
  # hop the Api client follows - the host is resolved to its IP address(es) and
  # the request is refused if any resolved address is loopback, private,
  # link-local (including the cloud metadata address 169.254.169.254), unspecified
  # or CGNAT. A non-http(s) scheme is refused.
  #
  # Off by default; TINA4_ALLOW_PRIVATE_REQUESTS (truthy) or an explicit allow-list
  # of hosts / host:port / CIDRs opts out. Zero external dependencies - Ruby
  # stdlib IPAddr + Resolv.
  module Ssrf
    ALLOW_PRIVATE_ENV = "TINA4_ALLOW_PRIVATE_REQUESTS"

    # Truthiness identical to ADR-0070's set (trimmed, lower-cased).
    TRUTHY = %w[1 true yes on].freeze

    # The blocked address space, one definition shared with the contract fixture.
    # 0.0.0.0/8 covers the unspecified address and the "this network" block.
    BLOCKED = %w[
      0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.168.0.0/16 100.64.0.0/10
      ::1/128 ::/128 fc00::/7 fe80::/10
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    module_function

    # True when TINA4_ALLOW_PRIVATE_REQUESTS opts out of the guard.
    def allow_private_requests?
      TRUTHY.include?(ENV.fetch(ALLOW_PRIVATE_ENV, "").strip.downcase)
    end

    # Classify one IP string: true = private/internal, refuse it. An IPv4-mapped
    # IPv6 address is classified by its embedded IPv4. An unparseable value is
    # treated as blocked - the guard refuses what it cannot classify.
    def blocked_address?(ip)
      addr = IPAddr.new(ip.to_s.split("%").first)
      addr = addr.native if addr.ipv6? && addr.ipv4_mapped?
      BLOCKED.any? { |network| network.include?(addr) }
    rescue IPAddr::Error
      true
    end

    # Refuse +url+ when it targets a private/internal address. Raises SsrfError
    # for a non-http(s) scheme, an unresolvable host, or any resolved address in
    # the blocked space. allow_hosts is a list of hosts / host:port / CIDRs.
    def guard_url!(url, allow_hosts = nil)
      uri = url.is_a?(URI) ? url : URI.parse(url.to_s)
      scheme = uri.scheme&.downcase
      unless %w[http https].include?(scheme)
        raise SsrfError, "Blocked request: URL scheme '#{scheme || '(none)'}' is not http or https"
      end
      host = uri.host.to_s
      raise SsrfError, "Blocked request: URL has no host" if host.empty?

      host = host.delete_prefix("[").delete_suffix("]")
      port = uri.port || (scheme == "https" ? 443 : 80)

      return if allow_private_requests?

      resolved = resolve(host)
      return if matches_allow_list?(host, port, resolved, allow_hosts)

      resolved.each do |ip|
        next unless blocked_address?(ip)

        log_block(host, ip)
        raise SsrfError,
              "Blocked request to private/internal address #{ip} (host #{host}): " \
              "set #{ALLOW_PRIVATE_ENV}=true to allow, or pass an allow-list."
      end
    end

    # Resolve a host to its IP address(es). An IP literal resolves to itself.
    def resolve(host)
      begin
        IPAddr.new(host)
        return [host]
      rescue IPAddr::Error
        # not a literal - fall through to DNS
      end
      addresses = begin
        Resolv.getaddresses(host)
      rescue StandardError
        []
      end
      if addresses.empty?
        begin
          addresses = [IPSocket.getaddress(host)]
        rescue SocketError
          addresses = []
        end
      end
      raise SsrfError, "Blocked request to #{host}: cannot resolve host" if addresses.empty?

      addresses
    end

    def matches_allow_list?(host, port, resolved, allow_hosts)
      host_lower = host.downcase
      Array(allow_hosts).each do |raw|
        entry = raw.to_s.strip.downcase
        next if entry.empty?
        return true if entry == host_lower || entry == "#{host_lower}:#{port}"

        next unless entry.include?("/")

        begin
          network = IPAddr.new(entry)
        rescue IPAddr::Error
          next
        end
        resolved.each do |ip|
          begin
            candidate = IPAddr.new(ip.to_s.split("%").first)
          rescue IPAddr::Error
            next
          end
          return true if network.include?(candidate)
        end
      end
      false
    end

    def log_block(host, ip)
      Tina4::Log.warning("SSRF guard blocked outbound request to #{host} (#{ip})") if defined?(Tina4::Log)
    rescue StandardError
      nil
    end
  end
end
