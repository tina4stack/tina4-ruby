# frozen_string_literal: true

require "json"
require "time"
require "openssl"
require "base64"

require_relative "realtime/workspace"
require_relative "realtime/channel"
require_relative "realtime/channel_member"
require_relative "realtime/message"
require_relative "realtime/attachment"
require_relative "realtime/storage_backend"
require_relative "realtime/local_storage"
require_relative "realtime/s3_storage"
require_relative "realtime/storage"

module Tina4
  # Real-time collaboration mount for Tina4 (Ruby), parity with the Python
  # master's tina4_python.realtime. A zero-dependency control plane for building
  # Slack/Teams-class tools:
  #
  # - calls: a WebRTC signalling relay + self-describing ICE-config endpoint.
  #   Media is peer-to-peer (mesh); Tina4 carries no media, it only relays the
  #   offer/answer/ICE handshake. An SFU drops in later with no route changes.
  # - chat: persistent channels + messages (framework-owned ORM models), a
  #   secured chat WebSocket with live presence / typing / read receipts, and a
  #   history endpoint for catch-up-on-reconnect.
  # - files: uploads/downloads through a pluggable StorageBackend.
  #
  # Paths are convention defaults, overridable via +prefix+, and the client
  # discovers the resolved paths from the config endpoint so client and server
  # never drift.
  #
  #   Tina4::Realtime.mount                                  # calls only
  #   Tina4::Realtime.mount(features: %w[calls chat])        # add persistent chat
  #   Tina4::Realtime.mount(prefix: "/api/collab", features: %w[calls chat files])
  #
  # Env: TINA4_RTC_BACKEND (default mesh), TINA4_RTC_STUN_URLS,
  # TINA4_RTC_TURN_URL + TINA4_RTC_TURN_SECRET (ephemeral coturn creds),
  # TINA4_RTC_TURN_TTL, plus the TINA4_STORAGE_* set for files.
  module Realtime
    DEFAULT_STUN = "stun:stun.l.google.com:19302"

    module_function

    # Build the ICE server list from the environment. Always includes STUN. Adds
    # a TURN entry with time-limited credentials (coturn use-auth-secret scheme:
    # username = <expiry-epoch>, credential = base64(HMAC-SHA1(secret, username)))
    # when both TINA4_RTC_TURN_URL and TINA4_RTC_TURN_SECRET are set.
    def ice_servers
      stun = ENV["TINA4_RTC_STUN_URLS"] || DEFAULT_STUN
      servers = [{ "urls" => split_urls(stun) }]

      turn_url = ENV["TINA4_RTC_TURN_URL"]
      secret = ENV["TINA4_RTC_TURN_SECRET"]
      if turn_url && !turn_url.empty? && secret && !secret.empty?
        ttl = (ENV["TINA4_RTC_TURN_TTL"] || "3600").to_i
        username = (Time.now.to_i + ttl).to_s
        credential = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA1", secret, username))
        servers << { "urls" => split_urls(turn_url), "username" => username, "credential" => credential }
      end
      servers
    end

    # Mount the realtime surface and return the resolved path map (also served
    # from the config endpoint so the client can discover it).
    #
    # @param prefix    [String] mount the whole surface under this path
    # @param authorize [Proc]   membership guard authorize.(identity, channel_id)
    #                            for chat/files; defaults to a ChannelMember check
    # @param storage   [StorageBackend] for the files feature
    # @param features  [Array<String>] any of "calls", "chat", "files"
    def mount(prefix: "", authorize: nil, storage: nil, features: nil)
      features = features || ["calls"]
      p = prefix.to_s.gsub(%r{\A/+|/+\z}, "")
      p = p.empty? ? "" : "/#{p}"
      @authorize = authorize
      @storage = storage

      # Chat and files both persist through the framework-owned chat models.
      ensure_chat_tables if features.include?("chat") || features.include?("files")

      paths = { "backend" => "mesh" }
      if features.include?("calls")
        paths["config"] = "#{p}/api/rtc/config"
        paths["signalling"] = "#{p}/ws/rtc"
      end
      if features.include?("chat")
        paths["config"] ||= "#{p}/api/rtc/config"
        paths["chat"] = "#{p}/ws/chat"
        paths["messages"] = "#{p}/api/channels"
      end
      if features.include?("files")
        paths["config"] ||= "#{p}/api/rtc/config"
        paths["files"] = "#{p}/api/files"
      end

      register_config(paths, features) if paths.key?("config")
      register_calls(paths) if features.include?("calls")
      register_chat(paths) if features.include?("chat")
      register_files(paths, storage) if features.include?("files")

      paths
    end

    # ----- route registration -------------------------------------------------

    def register_config(paths, features)
      Tina4::Router.get(paths["config"]) do |_request, response|
        body = { "backend" => "mesh" }
        if features.include?("calls")
          body["iceServers"] = Tina4::Realtime.ice_servers
          body["signalling"] = "#{paths['signalling']}/{room}"
        end
        if features.include?("chat")
          body["chat"] = "#{paths['chat']}/{channel}"
          body["messages"] = "#{paths['messages']}/{id}/messages"
        end
        body["files"] = paths["files"] if features.include?("files")
        response.json(body, Tina4::HTTP_OK)
      end
    end

    def register_calls(paths)
      # WebRTC signalling relay (mesh). Tina4 never parses the SDP; peers filter
      # by `to`. The signalling room is public - the media is E2E between peers.
      Tina4::Router.websocket("#{paths['signalling']}/{room}") do |connection, event, data|
        room = connection.params[:room].to_s
        next if room.empty?

        key = "rtc:#{room}"
        case event
        when :open
          connection.join_room(key)
        when :message
          connection.broadcast_to_room(key, data, exclude_self: true)
        end
      end
    end

    def register_chat(paths)
      Tina4::Router.websocket("#{paths['chat']}/{channel}") { |c, e, d| chat_handler(c, e, d) }.secure

      Tina4::Router.get("#{paths['messages']}/{id}/messages") do |request, response|
        identity = Tina4::Realtime.identity(request.user)
        channel_id = request.params[:id].to_i
        if channel_id <= 0
          response.json({ "error" => "invalid channel id" }, Tina4::HTTP_BAD_REQUEST)
        elsif !Tina4::Realtime.authorized?(identity, channel_id)
          response.json({ "error" => "forbidden" }, Tina4::HTTP_FORBIDDEN)
        else
          response.json(Tina4::Realtime.history(channel_id, request.query || {}), Tina4::HTTP_OK)
        end
      end.secure
    end

    def register_files(paths, storage)
      store = Tina4::Realtime::Storage.select(storage)

      # POST is auth-required by default (mirrors GET being public).
      Tina4::Router.post(paths["files"]) do |request, response|
        identity = Tina4::Realtime.identity(request.user)
        channel_id = Tina4::Realtime.form_value(request, "channel_id").to_i
        if channel_id <= 0
          response.json({ "error" => "channel_id is required" }, Tina4::HTTP_BAD_REQUEST)
        elsif !Tina4::Realtime.authorized?(identity, channel_id)
          response.json({ "error" => "forbidden" }, Tina4::HTTP_FORBIDDEN)
        else
          upload = request.files && request.files["file"]
          if upload.nil?
            response.json({ "error" => "no file uploaded (field 'file')" }, Tina4::HTTP_BAD_REQUEST)
          else
            saved = Tina4::Realtime.store_upload(store, channel_id, upload)
            saved["url"] = store.url(saved["key"]) || "#{paths['files']}/#{saved['key']}"
            response.json(saved, Tina4::HTTP_CREATED)
          end
        end
      end

      Tina4::Router.get("#{paths['files']}/{key}") do |request, response|
        identity = Tina4::Realtime.identity(request.user)
        key = request.params[:key].to_s
        att = Attachment.where("storage_key = ?", [key]).first
        if att.nil?
          response.json({ "error" => "not found" }, Tina4::HTTP_NOT_FOUND)
        elsif !Tina4::Realtime.authorized?(identity, att.channel_id.to_i)
          response.json({ "error" => "forbidden" }, Tina4::HTTP_FORBIDDEN)
        else
          direct = store.url(key)
          if direct
            response.redirect(direct, 302)
          else
            data = store.get(key)
            if data.nil?
              response.json({ "error" => "not found" }, Tina4::HTTP_NOT_FOUND)
            else
              response.header("Content-Disposition", "inline; filename=\"#{att.filename || key}\"")
              response.call(data, Tina4::HTTP_OK, att.mime || "application/octet-stream")
            end
          end
        end
      end.secure
    end

    # ----- WebSocket chat handler ---------------------------------------------

    # Secured chat WebSocket. Ruby fires (connection, event, data); event is a
    # Symbol (:open / :message / :close).
    def chat_handler(connection, event, data)
      raw = connection.params[:channel].to_s
      return unless raw.match?(/\A\d+\z/) # framework channels are addressed by integer id

      channel_id = raw.to_i
      identity = identity(connection.auth)
      key = "chat:#{channel_id}"

      case event
      when :open
        unless authorized?(identity, channel_id)
          connection.send_json({ "type" => "error", "error" => "not a member of this channel" })
          connection.close
          return
        end
        connection.join_room(key)
        connection.send_json({ "type" => "presence", "event" => "roster", "users" => roster(key) })
        connection.broadcast_to_room(
          key, { "type" => "presence", "event" => "join", "user_id" => identity }.to_json, exclude_self: true
        )
      when :close
        connection.broadcast_to_room(
          key, { "type" => "presence", "event" => "leave", "user_id" => identity }.to_json, exclude_self: true
        )
      when :message
        # Re-check membership on every inbound frame: it can be revoked
        # mid-session, and we never trust a payload's identity.
        return unless authorized?(identity, channel_id)

        payload = parse_json(data)
        return unless payload.is_a?(Hash)

        kind = payload["type"] || "message"
        case kind
        when "typing"
          connection.broadcast_to_room(
            key, { "type" => "typing", "user_id" => identity }.to_json, exclude_self: true
          )
        when "read"
          mark_read(channel_id, identity)
          connection.broadcast_to_room(
            key, { "type" => "read", "user_id" => identity, "at" => now_iso }.to_json, exclude_self: true
          )
        when "message"
          body = (payload["body"] || "").to_s.strip
          return if body.empty?

          saved = persist_message(channel_id, identity, body, payload["thread_id"])
          # Deliver to everyone INCLUDING the sender so the sender's optimistic
          # message is reconciled with its server id + timestamp.
          connection.broadcast_to_room(key, { "type" => "message", "message" => saved }.to_json) if saved
        end
      end
    end

    # ----- helpers ------------------------------------------------------------

    # Extract a stable user identity from a verified JWT payload. Chat expects
    # one of user_id / sub / id. Returns a string, or nil when unauthenticated.
    def identity(auth)
      return nil unless auth.is_a?(Hash)

      %w[user_id sub id].each do |claim|
        val = auth[claim] || auth[claim.to_sym]
        return val.to_s unless val.nil?
      end
      nil
    end

    # Shared membership guard for chat channels and file access.
    def authorized?(identity, channel_id)
      return false if identity.nil?
      return !!@authorize.call(identity, channel_id) unless @authorize.nil?

      ChannelMember.count("channel_id = ? AND user_id = ?", [channel_id, identity]).positive?
    rescue StandardError => e
      Tina4::Log.error("realtime chat authorize check failed: #{e.message}")
      false
    end

    # Presence roster: the distinct authenticated identities currently in a room,
    # as strings (sorted). Collected from the live connections on the manager.
    def roster(key)
      mgr = Tina4::WebSocket.current
      return [] if mgr.nil?

      seen = mgr.get_room_connections(key).map { |c| identity(c.auth) }.compact
      seen.uniq.sort
    end

    def form_value(request, name)
      body = request.body
      return body[name] if body.is_a?(Hash) && body.key?(name)

      # Its only caller is on POST #{paths['files']}, a route with no path
      # segments — a `request.params` fallback here would only ever have
      # matched a route param that this path can never have, so it is not
      # carried forward now that `params` is route-only (REQ-PARAM-POLLUTION,
      # 3.13.99): body, then the query string, is the complete real source list.
      request.query && request.query[name]
    end

    def parse_json(data)
      return data if data.is_a?(Hash)

      JSON.parse(data.to_s)
    rescue JSON::ParserError, TypeError
      nil
    end

    def now_iso
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def persist_message(channel_id, identity, body, thread_id)
      thread = thread_id.nil? || thread_id == "" ? nil : thread_id.to_i
      created_at = now_iso
      msg = Message.new(
        channel_id: channel_id, user_id: identity.to_s, body: body,
        thread_id: thread, created_at: created_at
      )
      if msg.save == false
        Tina4::Log.error("realtime chat: failed to persist message in channel #{channel_id}")
        return nil
      end
      {
        "id" => msg.id, "channel_id" => channel_id, "user_id" => identity.to_s,
        "body" => body, "thread_id" => thread, "created_at" => created_at
      }
    end

    def mark_read(channel_id, identity)
      member = ChannelMember.where("channel_id = ? AND user_id = ?", [channel_id, identity]).first
      return if member.nil?

      member.last_read_at = now_iso
      member.save
    rescue StandardError => e
      Tina4::Log.error("realtime chat: read-receipt update failed: #{e.message}")
    end

    # Messages for a channel, newest-first, paged by a `before` cursor. The
    # standard infinite-scroll-backwards shape a chat client pages with.
    def history(channel_id, query)
      limit = (query["limit"] || query[:limit] || 50).to_i
      limit = 50 if limit <= 0
      limit = [[limit, 1].max, 200].min
      before = query["before"] || query[:before]

      clause = "channel_id = ?"
      params = [channel_id]
      unless before.nil? || before.to_s.empty?
        clause += " AND id < ?"
        params << before.to_i
      end

      rows = Message.where(clause, params)
      rows = rows.sort_by { |m| -(m.id || 0) }.first(limit)
      rows.map do |m|
        {
          "id" => m.id, "channel_id" => m.channel_id, "user_id" => m.user_id,
          "body" => m.body, "thread_id" => m.thread_id, "created_at" => m.created_at
        }
      end
    end

    def store_upload(store, channel_id, upload)
      filename = upload["filename"] || upload[:filename] || "file"
      mime = upload["type"] || upload[:type] || "application/octet-stream"
      content = upload["content"] || upload[:content] || ""
      key = Tina4::Realtime::Storage.key(filename)
      store.put(key, content, mime)
      att = Attachment.new(
        channel_id: channel_id, storage_key: key, filename: filename,
        mime: mime, size: content.bytesize
      )
      att.save
      { "id" => att.id, "key" => key, "filename" => filename, "mime" => mime, "size" => content.bytesize }
    end

    def ensure_chat_tables
      [Workspace, Channel, ChannelMember, Message, Attachment].each(&:create_table)
      true
    rescue StandardError => e
      Tina4::Log.error(
        "realtime chat could not create its tables (#{e.message}). Chat needs a bound " \
        "database - call Tina4.bind_database(db) or set TINA4_DATABASE_URL before mount."
      )
      false
    end

    def split_urls(csv)
      csv.split(",").map(&:strip).reject(&:empty?)
    end
  end
end
