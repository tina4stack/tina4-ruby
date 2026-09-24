# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
require "spec_helper"
require "stringio"

RSpec.describe "credential file permissions" do
  around do |example|
    saved = ENV.to_h
    old_keys = Tina4::Auth.instance_variable_get(:@keys_dir)
    Dir.mktmpdir("secret-files") do |dir|
      Dir.chdir(dir) do
        ENV["TINA4_DEBUG"] = "true"
        ENV["TINA4_ENV"] = "development"
        ENV.delete("CI")
        ENV.delete("TINA4_SECRET")
        ENV.delete("TINA4_API_KEY")
        Tina4::Router.clear!
        example.run
      end
    end
  ensure
    ENV.replace(saved)
    Tina4::Auth.instance_variable_set(:@keys_dir, old_keys)
    Tina4::Router.clear!
  end

  def save_credentials(writer)
    return Tina4::Auth.ensure_dev_secret if writer == :auth
    path, data = writer == :grounding ? ["grounding/token", {token: "private-token"}] :
      ["connections/save", {url: "sqlite3:app.db", username: "user", password: "private-password"}]
    raw = JSON.generate(data)
    status, _, body = Tina4::RackApp.new.call({
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "/__dev/api/#{path}",
      "QUERY_STRING" => "", "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147",
      "REMOTE_ADDR" => "127.0.0.1", "rack.url_scheme" => "http",
      "HTTP_SEC_FETCH_SITE" => "same-origin", "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => raw.bytesize.to_s, "rack.input" => StringIO.new(raw),
      "rack.errors" => StringIO.new
    })
    expect(status).to eq(200)
    JSON.parse(body.to_a.join)
  end

  [:auth, :grounding, :connection].each do |writer|
    [:new, :existing, :symlink, :hardlink].each do |kind|
      it "#{writer} safely persists #{kind} credential files" do
        skip "[needs:os=posix] POSIX file permissions" if Gem.win_platform?
        path = writer == :auth ? ".env.local" : ".env"
        File.write("unrelated", "KEEP=original\n")
        File.chmod(0o644, "unrelated")
        case kind
        when :existing
          File.write(path, "KEEP=original\n")
          File.chmod(0o644, path)
        when :symlink then File.symlink("unrelated", path)
        when :hardlink then File.link("unrelated", path)
        end
        result = save_credentials(writer)
        if [:symlink, :hardlink].include?(kind)
          expect(File.read("unrelated")).to eq("KEEP=original\n")
          expect(File.stat("unrelated").mode & 0o777).to eq(0o644)
          if writer == :auth
            expect(result).to eq(ENV["TINA4_SECRET"])
            expect(result).to match(/\A[0-9a-f]{64}\z/)
          else
            expect(result[writer == :grounding ? "ok" : "success"]).to eq(false)
          end
        else
          expect(File.stat(path).mode & 0o777).to eq(0o600)
          expect(File.read(path)).to include("KEEP=original") if kind == :existing
          expected = writer == :auth ? "TINA4_SECRET=#{result}" : writer == :grounding ? "TINA4_MCP_TOKEN=private-token" : "TINA4_DATABASE_PASSWORD=private-password"
          expect(File.read(path)).to include(expected)
        end
      end
    end
  end

  [:new, :existing, :symlink, :hardlink].each do |kind|
    it "RSA private key safely handles #{kind} files" do
      skip "[needs:os=posix] POSIX file permissions" if Gem.win_platform?
      Dir.mkdir("keys")
      Tina4::Auth.instance_variable_set(:@keys_dir, File.expand_path("keys"))
      File.write("unrelated", "original")
      File.chmod(0o644, "unrelated")
      case kind
      when :existing then File.write("keys/private.pem", "old"); File.chmod(0o644, "keys/private.pem")
      when :symlink then File.symlink(File.expand_path("unrelated"), "keys/private.pem")
      when :hardlink then File.link("unrelated", "keys/private.pem")
      end
      if [:symlink, :hardlink].include?(kind)
        expect { Tina4::Auth.send(:generate_keys) }.to raise_error(StandardError)
        expect(File.read("unrelated")).to eq("original")
        expect(File.stat("unrelated").mode & 0o777).to eq(0o644)
      else
        Tina4::Auth.send(:generate_keys)
        expect(File.stat("keys/private.pem").mode & 0o777).to eq(0o600)
        expect(OpenSSL::PKey::RSA.new(File.read("keys/private.pem"))).to be_private
      end
    end
  end
end
