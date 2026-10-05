# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# A request that writes nothing to the session stores no session and sets no
# session cookie.
#
# Ruby already stored nothing for a session no route wrote to (Request#session
# is lazy and #save no-ops for a new, unmodified session). But any request that
# touched request.session without writing - a route that only reads it, or one
# carrying a cookie the store does not know - was handed a freshly minted id in
# a Set-Cookie, for a session that was never stored: the next request could not
# resume it either, so it was handed another. php and nodejs stored a session
# for every request too (static files, 404s and /health included).
#
# A REAL Tina4::WebServer child, real sockets: every case counts the session
# files and reads every Set-Cookie line off the wire.

require "spec_helper"
require "securerandom"
require "socket"
require "timeout"
require_relative "support/shutdown_probe"

module SessionAnonymousRequestProbe
  module_function

  def write_app(dir)
    lib = ShutdownProbe.worktree_lib
    FileUtils.mkdir_p(File.join(dir, "src", "public"))
    File.write(File.join(dir, "src", "public", "hello.txt"), "static file")
    app_path = File.join(dir, "app.rb")
    File.write(app_path, <<~RUBY)
      #{ShutdownProbe.load_guard(lib)}

      Tina4::Router.get("/plain") do |request, response|
        response.call("plain", Tina4::HTTP_OK)
      end.no_auth

      Tina4::Router.get("/read") do |request, response|
        response.call("user=\#{request.session.get('user') || '-'}", Tina4::HTTP_OK)
      end.no_auth

      Tina4::Router.get("/write") do |request, response|
        request.session.set("user", "alice")
        response.call("wrote", Tina4::HTTP_OK)
      end.no_auth

      # Calls that mark a session changed without leaving anything in it. A
      # record with no data is not a session, so none may store one.
      Tina4::Router.get("/clear") do |request, response|
        request.session.clear
        response.call("cleared", Tina4::HTTP_OK)
      end.no_auth

      Tina4::Router.get("/delete-missing") do |request, response|
        request.session.delete("never-set")
        response.call("deleted nothing", Tina4::HTTP_OK)
      end.no_auth

      Tina4::Router.get("/set-then-delete") do |request, response|
        request.session.set("a", "1")
        request.session.delete("a")
        response.call("set then deleted", Tina4::HTTP_OK)
      end.no_auth

      Tina4::Router.get("/regenerate-empty") do |request, response|
        request.session.regenerate
        response.call("regenerated", Tina4::HTTP_OK)
      end.no_auth

      Tina4::Router.get("/read-flash") do |request, response|
        response.call("flash=\#{request.session.get_flash('error') || '-'}", Tina4::HTTP_OK)
      end.no_auth

      Tina4.initialize!(#{dir.inspect})
      application = Tina4::RackApp.new(root_dir: #{dir.inspect})
      Tina4::WebServer.new(application, host: "127.0.0.1",
                                        port: Integer(ENV.fetch("PROBE_PORT"))).start
    RUBY
    app_path
  end

  def boot(store)
    dir = SpecTmpdir.create("tina4-session-anonymous")
    port = ShutdownProbe.free_port
    app_path = write_app(dir)
    log_path = File.join(dir, "server.log")

    child_env = ShutdownProbe.base_env("TINA4_OVERRIDE_CLIENT" => "true", "PROBE_PORT" => port.to_s,
                                       "TINA4_SESSION_BACKEND" => "file", "TINA4_SESSION_PATH" => store)
    pid = spawn(child_env, RbConfig.ruby, app_path,
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    ShutdownProbe::Server.new(pid, port, dir, log_path).wait_until_serving!("/plain")
  end

  # Raw socket GET so every Set-Cookie header is visible.
  def raw_get(port, path, cookie: nil, timeout: 5)
    socket = Socket.tcp("127.0.0.1", port, connect_timeout: timeout)
    lines = ["GET #{path} HTTP/1.1", "Host: 127.0.0.1:#{port}", "Connection: close"]
    lines << "Cookie: #{cookie}" if cookie
    socket.write(lines.join("\r\n") + "\r\n\r\n")
    raw = +""
    begin
      Timeout.timeout(timeout) { loop { raw << socket.readpartial(4096) } }
    rescue EOFError, Timeout::Error, Errno::ECONNRESET
      # whatever we got is the answer
    end
    socket.close
    head, _sep, body = raw.partition("\r\n\r\n")
    set_cookies = head.split("\r\n").select { |l| l =~ /\Aset-cookie:/i }
                      .map { |l| l.split(":", 2)[1].to_s.strip }
    { body: body, set_cookies: set_cookies }
  end
end

RSpec.describe "Session - a request that writes nothing stores no session and sets no cookie" do
  # One server for the group: booting a child is the slow part.
  before(:all) do
    @store = SpecTmpdir.create("tina4-session-anonymous-store")
    @server = SessionAnonymousRequestProbe.boot(@store)
  end
  after(:all) { @server&.destroy! }

  def files
    Dir.glob(File.join(@store, "**", "*")).count { |p| File.file?(p) }
  end

  EMPTY_TOUCHES = {
    "a route that clears the session" => "/clear",
    "a route that deletes a key it never set" => "/delete-missing",
    "a route that sets then deletes a key" => "/set-then-delete",
    "a route that regenerates an empty session" => "/regenerate-empty",
    "a route that reads a flash message" => "/read-flash"
  }.freeze

  {
    "a static file" => "/hello.txt", "a 404" => "/missing", "/health" => "/health",
    "a route that never touches the session" => "/plain", "a route that reads the session" => "/read"
  }.merge(EMPTY_TOUCHES).each do |what, path|
    it "#{what} stores no session and sets no cookie" do
      before = files
      3.times do
        reply = SessionAnonymousRequestProbe.raw_get(@server.port, path)
        expect(reply[:set_cookies]).to eq([]), "#{path} must set no cookie\n--- server log ---\n#{@server.log}"
      end
      expect(files).to eq(before)
    end
  end

  EMPTY_TOUCHES.each do |what, path|
    it "#{what}, with a cookie the store never issued, stores nothing" do
      before = files
      3.times do
        reply = SessionAnonymousRequestProbe.raw_get(@server.port, path, cookie: "tina4_session=#{SecureRandom.hex(32)}")
        expect(reply[:set_cookies]).to eq([]), "#{path} must set no cookie\n--- server log ---\n#{@server.log}"
      end
      expect(files).to eq(before)
    end
  end

  it "clearing a stored session still ends it" do
    # Only a session nothing ever stored is skipped for being empty. One the
    # store holds that a request empties is a logout: its record must go, or the
    # next request is logged straight back in.
    write = SessionAnonymousRequestProbe.raw_get(@server.port, "/write")
    pair = write[:set_cookies].find { |c| c.start_with?("tina4_session=") }.split(";", 2).first
    expect(SessionAnonymousRequestProbe.raw_get(@server.port, "/read", cookie: pair)[:body]).to eq("user=alice")
    SessionAnonymousRequestProbe.raw_get(@server.port, "/clear", cookie: pair)
    expect(SessionAnonymousRequestProbe.raw_get(@server.port, "/read", cookie: pair)[:body]).to eq("user=-")
  end

  it "a cookie the store never issued gets no replacement cookie" do
    before = files
    reply = SessionAnonymousRequestProbe.raw_get(@server.port, "/read", cookie: "tina4_session=#{SecureRandom.hex(32)}")
    expect(reply[:body]).to eq("user=-")
    expect(reply[:set_cookies]).to eq([])
    expect(files).to eq(before)
  end

  it "a write stores the session and a replay resumes it" do
    before = files
    write = SessionAnonymousRequestProbe.raw_get(@server.port, "/write")
    session_cookies = write[:set_cookies].select { |c| c.start_with?("tina4_session=") }
    expect(session_cookies.size).to eq(1), "got #{write[:set_cookies].inspect}"
    expect(files).to eq(before + 1)
    read = SessionAnonymousRequestProbe.raw_get(@server.port, "/read", cookie: session_cookies.first.split(";", 2).first)
    expect(read[:body]).to eq("user=alice")
    expect(read[:set_cookies]).to eq([])
  end

  it "a fresh session is fresh until its first write" do
    session = Tina4::Session.new({ "HTTP_COOKIE" => "" }, handler: :file, handler_options: { dir: @store })
    expect(session.fresh?).to be(true)
    session.get("user")
    expect(session.fresh?).to be(true)
    session.set("user", "alice")
    expect(session.fresh?).to be(false)
  end

  it "a session changed and emptied again is fresh, and saving it writes nothing" do
    session = Tina4::Session.new({ "HTTP_COOKIE" => "" }, handler: :file, handler_options: { dir: @store })
    before = files
    session.set("a", "1")
    session.delete("a")
    expect(session.fresh?).to be(true)
    expect(session.save).to be(true)
    expect(files).to eq(before)
  end
end
