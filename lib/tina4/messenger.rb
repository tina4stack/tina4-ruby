# frozen_string_literal: true

begin
  require "net/smtp"
rescue LoadError
  # net-smtp gem needed on Ruby >= 4.0: gem install net-smtp
end
begin
  require "net/imap"
rescue LoadError
  # net-imap gem needed on Ruby >= 4.0: gem install net-imap
end
require "base64"
require "securerandom"
require "time"
require "socket"
require "timeout"
begin
  require "openssl"
rescue LoadError
  # openssl is part of stdlib; absence only affects TLS error classification
end

module Tina4
  # Raised on a messenger failure (base class).
  class MessengerError < StandardError; end

  # Raised when an IMAP read fails to connect, authenticate, or speak the
  # protocol. Distinct from a successful fetch that simply has no messages —
  # that still returns an empty result ([]/nil/0/{}), NOT an error.
  #
  # Subclasses MessengerError so existing `rescue Tina4::MessengerError`
  # handlers still catch it.
  class MessengerConnectionError < MessengerError; end

  # Errors that mean "we could not talk to the mail server", as opposed to
  # "we talked fine and the mailbox is empty". These must fail loud — LOG and
  # RAISE — never be silently swallowed into an empty result. Mirrors the
  # Python master's _IMAP_CONNECTION_ERRORS tuple.
  #
  # Built lazily so a missing net/imap gem (LoadError above) doesn't break
  # loading this file.
  IMAP_CONNECTION_ERRORS = [
    SocketError,            # DNS / host resolution failures
    IOError,                # closed/broken stream, EOF mid-conversation
    SystemCallError,        # Errno::ECONNREFUSED / ECONNRESET / ETIMEDOUT etc.
    Timeout::Error,         # connect/read timeout (Net::OpenTimeout descends from this)
    MessengerError          # our own protocol-failure signal (re-raised as-is)
  ].tap do |errors|
    errors << Net::IMAP::Error if defined?(Net::IMAP::Error)
    errors << OpenSSL::SSL::SSLError if defined?(OpenSSL::SSL::SSLError)
  end.freeze

  # Tina4 Messenger — Email sending (SMTP) and reading (IMAP).
  #
  # Unified .env-driven configuration with constructor override.
  # Priority: constructor params > .env (TINA4_MAIL_*) > sensible defaults
  #
  #   # .env
  #   TINA4_MAIL_HOST=smtp.gmail.com
  #   TINA4_MAIL_PORT=587
  #   TINA4_MAIL_USERNAME=user@gmail.com
  #   TINA4_MAIL_PASSWORD=app-password
  #   TINA4_MAIL_FROM=noreply@myapp.com
  #   TINA4_MAIL_ENCRYPTION=tls
  #   TINA4_MAIL_IMAP_HOST=imap.gmail.com
  #   TINA4_MAIL_IMAP_PORT=993
  #
  #   mail = Messenger.new                                        # reads from .env
  #   mail = Messenger.new(host: "smtp.office365.com", port: 587) # override
  #   mail.send(to: "user@test.com", subject: "Welcome", body: "<h1>Hello!</h1>", html: true, text: "Hello!")
  #
  class Messenger
    # Factory: returns a Messenger configured for the current environment.
    #
    # Returns ONE concrete type, always. It used to return either a Messenger or a
    # DevMessengerProxy; both happened to expose #send, so Ruby escaped the crash that
    # nodejs#41 describes by luck of naming rather than by design -- but the proxy's
    # #send took no text: keyword, so the documented call raised ArgumentError on a dev
    # messenger. Capture is now a branch inside Messenger#send.
    #
    # The gate is availability, not verbosity: capture when no SMTP host is configured,
    # send when one is EVEN WITH TINA4_DEBUG ON, and TINA4_MAIL_CAPTURE forces capture.
    def self.create_messenger(**options)
      mailbox_dir = options.delete(:mailbox_dir) || ENV["TINA4_MAILBOX_DIR"]
      messenger = Messenger.new(**options)
      messenger.instance_variable_set(:@mailbox_dir, mailbox_dir)

      # Attach the mailbox eagerly when this messenger will capture, so callers (and
      # the dev dashboard) can inspect it before the first send.
      messenger.dev_mailbox = DevMailbox.new(mailbox_dir: mailbox_dir) if messenger.should_capture?

      messenger
    end

    attr_reader :host, :port, :username, :from_address, :from_name,
                :imap_host, :imap_port, :use_tls, :encryption,
                :imap_encryption, :imap_use_tls, :imap_username, :imap_password

    # Initialize with SMTP config.
    # Priority: constructor params > ENV (TINA4_MAIL_*) > sensible defaults
    def initialize(host: nil, port: nil, username: nil, password: nil,
                   from_address: nil, from_name: nil, encryption: nil, use_tls: nil,
                   imap_host: nil, imap_port: nil, imap_encryption: nil,
                   imap_username: nil, imap_password: nil)
      # Whether a host was actually CONFIGURED, which is not the same as @host being
      # set: it falls back to "localhost", so it is never nil and cannot answer
      # "can this messenger send?". The capture gate needs that answer, so record it
      # here while the real inputs are still in scope.
      configured_host = host || ENV["TINA4_MAIL_HOST"]
      @smtp_configured = !configured_host.nil? && !configured_host.to_s.empty?
      @mailbox_dir = nil
      @dev_mailbox = nil
      @host         = host         || ENV["TINA4_MAIL_HOST"]     || "localhost"
      @port         = (port        || ENV["TINA4_MAIL_PORT"]     || 587).to_i
      @username     = username     || ENV["TINA4_MAIL_USERNAME"]
      @password     = password     || ENV["TINA4_MAIL_PASSWORD"]

      resolved_from = from_address || ENV["TINA4_MAIL_FROM"]
      @from_address = resolved_from || @username || "noreply@localhost"

      @from_name    = from_name    || ENV["TINA4_MAIL_FROM_NAME"] || ""

      # SMTP encryption: constructor > .env > backward-compat use_tls > default "tls"
      env_encryption = encryption  || ENV["TINA4_MAIL_ENCRYPTION"]
      if env_encryption
        @encryption = env_encryption.downcase
      elsif !use_tls.nil?
        @encryption = use_tls ? "tls" : "none"
      else
        @encryption = "tls"
      end
      @use_tls = %w[tls starttls].include?(@encryption)

      @imap_host    = imap_host    || ENV["TINA4_MAIL_IMAP_HOST"] || @host
      @imap_port    = (imap_port   || ENV["TINA4_MAIL_IMAP_PORT"] || 993).to_i

      # IMAP encryption: dedicated env var TINA4_MAIL_IMAP_ENCRYPTION (tls/starttls/none).
      # Defaults to "tls" — IMAPS over implicit TLS on port 993 is the safe industry norm.
      env_imap_enc = imap_encryption || ENV["TINA4_MAIL_IMAP_ENCRYPTION"]
      @imap_encryption = (env_imap_enc && !env_imap_enc.to_s.empty?) ? env_imap_enc.to_s.downcase : "tls"
      @imap_use_tls    = %w[tls starttls ssl].include?(@imap_encryption)

      # IMAP credentials, independent of SMTP. Dedicated
      # TINA4_MAIL_IMAP_USERNAME/_PASSWORD, falling back to the SMTP
      # TINA4_MAIL_USERNAME/_PASSWORD. Ruby authenticated IMAP to the SMTP
      # account, so an app whose mailbox for READING differs from its SMTP relay
      # account read the wrong mailbox. Explicit constructor args win (ADR-0041).
      @imap_username = imap_username || ENV["TINA4_MAIL_IMAP_USERNAME"] || @username
      @imap_password = imap_password || ENV["TINA4_MAIL_IMAP_PASSWORD"] || @password
    end

    # Send email using Ruby's Net::SMTP
    # Returns { success: true/false, message: "...", id: "..." }
    # The local mailbox, present only once this messenger has captured something
    # (or eagerly, when create_messenger knows it will).
    attr_accessor :dev_mailbox

    # Should send capture locally instead of talking to SMTP?
    #
    # Availability decides, not verbosity. With no SMTP host configured sending is
    # impossible, so simulate it into a folder rather than failing -- that is what
    # makes a laptop with no mail server usable, and it is the original Tina4
    # "messages folder" behaviour restored. TINA4_MAIL_CAPTURE forces capture even
    # when a host IS configured.
    #
    # TINA4_DEBUG deliberately does NOT gate this. Debug must still be able to send:
    # tying capture to it means nobody can test a real send from a dev box. The old
    # gate required debug AND no SMTP host, so a dev box with neither set went
    # straight to localhost:587 and failed.
    def should_capture?
      return true if Tina4::Env.is_truthy(ENV["TINA4_MAIL_CAPTURE"])

      !@smtp_configured
    end

    def dev_mailbox
      @dev_mailbox ||= DevMailbox.new(mailbox_dir: @mailbox_dir)
    end

    def send(to:, subject:, body:, html: false, text: nil, cc: [], bcc: [],
             reply_to: nil, attachments: [], headers: {})
      # Dev capture is a BRANCH here, not a different object handed back by the
      # factory. create_messenger used to return a DevMessengerProxy whose #send had
      # no text: keyword at all, so the documented call raised ArgumentError and the
      # plain-text alternative was silently dropped from the captured message.
      if should_capture?
        return dev_mailbox.capture(
          to: to, subject: subject, body: body, html: html, text: text,
          cc: cc, bcc: bcc, reply_to: reply_to,
          from_address: @from_address, from_name: @from_name,
          attachments: attachments
        )
      end

      # TINA4_MAIL_REDIRECT_TO (MAIL-DEC-01): the REAL-SEND path only --
      # capture already returned above, so this never touches the capture
      # branch. When the list is non-empty, replace every recipient with the
      # redirect list (so ONLY the dev list receives the mail, never the real
      # recipients) and preserve the originals in a header. Subject/body/
      # attachments are untouched; #send's return shape is unchanged. Read
      # fresh per call, matching should_capture?'s own env-read style.
      redirect_to = parse_mail_redirect_list(ENV["TINA4_MAIL_REDIRECT_TO"])
      unless redirect_to.empty?
        original_to = (normalize_recipients(to) + normalize_recipients(cc) + normalize_recipients(bcc)).join(", ")
        to = redirect_to
        cc = []
        bcc = []
        headers = (headers || {}).merge("X-Tina4-Original-To" => original_to)
      end

      message_id = "<#{SecureRandom.uuid}@#{@host}>"
      raw = build_message(
        to: to, subject: subject, body: body, html: html, text: text,
        cc: cc, bcc: bcc, reply_to: reply_to,
        attachments: attachments, headers: headers,
        message_id: message_id
      )

      all_recipients = normalize_recipients(to) +
                       normalize_recipients(cc) +
                       normalize_recipients(bcc)

      smtp = Net::SMTP.new(@host, @port)
      smtp.enable_starttls if @use_tls

      smtp.start(@host, @username, @password, auth_method) do |conn|
        conn.send_message(raw, @from_address, all_recipients)
      end

      Tina4::Log.info("Email sent to #{Array(to).join(', ')}: #{subject}")
      { success: true, message: "Email sent successfully", id: message_id }
    rescue => e
      Tina4::Log.error("Email send failed: #{e.message}")
      { success: false, message: e.message, id: nil }
    end

    # Send an email whose HTML body is rendered from a Frond template string.
    # Parity with the Python master's send_template. Extra keyword args (cc, bcc,
    # attachments, reply_to, headers, text) pass straight through to #send. If
    # Frond is unusable, the raw template string is sent as-is (a graceful
    # fallback, mirroring Python's ImportError branch).
    #
    #   mail.send_template(to: "u@x.com", subject: "Hi {{ name }}",
    #                      template: "<h1>Hi {{ name }}</h1>", data: { "name" => "Al" })
    def send_template(to:, subject:, template:, data: {}, **kwargs)
      body = begin
        Tina4::Frond.new.render_string(template, data || {})
      rescue StandardError => e
        Tina4::Log.error("Messenger send_template render failed: #{e.message}")
        template
      end
      send(to: to, subject: subject, body: body, html: true, **kwargs)
    end

    # Test SMTP connection
    # Returns { success: true/false, message: "..." }
    def test_connection
      smtp = Net::SMTP.new(@host, @port)
      smtp.enable_starttls if @use_tls
      smtp.start(@host, @username, @password, auth_method) do |_conn|
        # connection succeeded
      end
      { success: true, message: "SMTP connection successful" }
    rescue => e
      { success: false, message: e.message }
    end

    # ── IMAP operations ──────────────────────────────────────────────────

    # List messages in a folder.
    #
    # Callable POSITIONALLY — inbox("INBOX", 10, 0) — or by keyword —
    # inbox(folder: "INBOX", limit: 10). Node moved to folder-first in 3.13.95
    # to satisfy a contract Ruby could not satisfy at all; this closes that loop.
    #
    # Each item is EXACTLY {uid:String, subject, from:String, to:String,
    # date:ISO-8601, snippet, seen:Boolean} — the settled cross-framework shape.
    #
    # Raises Tina4::MessengerConnectionError on a connection/auth/protocol
    # failure (FAILS LOUD — never returns [] to hide it). A successful fetch
    # from an empty folder returns [] (that is NOT an error).
    def inbox(folder = "INBOX", limit = 20, offset = 0, **opts)
      folder = opts[:folder] if opts.key?(:folder)
      limit  = opts[:limit]  if opts.key?(:limit)
      offset = opts[:offset] if opts.key?(:offset)

      imap = imap_open("inbox")
      begin
        imap.select(folder)
        uids = imap.uid_search(["ALL"])
        uids = uids.reverse # newest first
        page = uids[offset, limit] || []
        return [] if page.empty?

        # BODY.PEEK[] fetches the full message WITHOUT setting \Seen — listing an
        # inbox must never mark messages read — so parse_envelope can build a
        # decoded, transfer-decoded, tag-stripped snippet. tina4: heavier than a
        # header-only fetch for large mailboxes; fetch BODYSTRUCTURE + the text
        # part only if this ever gets hot.
        envelopes = imap.uid_fetch(page, ["ENVELOPE", "FLAGS", "BODY.PEEK[]"])
        # uid_fetch returns rows in SERVER (ascending) order however the uids
        # were asked for, so the newest-first page above was silently re-sorted
        # and inbox(limit: 1) handed back the OLDEST message. Selection was
        # right; presentation was not. Restore the requested order.
        by_uid = (envelopes || []).each_with_object({}) { |m, h| h[m.attr["UID"]] = m }
        page.filter_map { |uid| by_uid[uid] }.map { |msg| parse_envelope(msg) }
      rescue *IMAP_CONNECTION_ERRORS => e
        raise imap_fail("inbox", e)
      ensure
        imap_cleanup(imap)
      end
    end

    # Read a single message by UID.
    #
    # Callable POSITIONALLY — read(uid, "INBOX") — or by keyword —
    # read(uid, folder: "INBOX"). Returns EXACTLY these 10 keys: {uid, subject,
    # from:String, to:String, cc:String, date:ISO-8601, body_text, body_html,
    # attachments, headers}. Message-ID lives in headers, never a top-level key.
    # Each attachments item is {filename, content_type, size, content} where
    # content is the RAW DECODED BYTES of the part (issue #69).
    #
    # Raises Tina4::MessengerConnectionError on a connection/protocol failure.
    # A successful fetch for a non-existent UID returns nil (that is NOT an error).
    def read(uid, folder = "INBOX", mark_read = true, **opts)
      folder    = opts[:folder]    if opts.key?(:folder)
      mark_read = opts[:mark_read] if opts.key?(:mark_read)

      imap = imap_open("read")
      begin
        imap.select(folder)
        data = imap.uid_fetch(uid, ["ENVELOPE", "FLAGS", "BODY[]", "RFC822.SIZE"])
        return nil if data.nil? || data.empty?

        if mark_read
          imap.uid_store(uid, "+FLAGS", [:Seen])
        end

        msg = data.first
        parse_full_message(msg)
      rescue *IMAP_CONNECTION_ERRORS => e
        raise imap_fail("read", e)
      ensure
        imap_cleanup(imap)
      end
    end

    # Count unread messages.
    #
    # Raises Tina4::MessengerConnectionError on a connection/protocol failure.
    # A successful query with no unseen messages returns 0 (NOT an error).
    def unread(folder: "INBOX")
      imap = imap_open("unread")
      begin
        imap.select(folder)
        uids = imap.uid_search(["UNSEEN"])
        uids.length
      rescue *IMAP_CONNECTION_ERRORS => e
        raise imap_fail("unread", e)
      ensure
        imap_cleanup(imap)
      end
    end

    # Search messages with filters.
    #
    # Raises Tina4::MessengerConnectionError on a connection/protocol failure.
    # A successful search with no matches returns [] (NOT an error).
    def search(folder: "INBOX", subject: nil, sender: nil, since: nil,
               before: nil, unseen_only: false, limit: 20)
      imap = imap_open("search")
      begin
        imap.select(folder)
        criteria = build_search_criteria(
          subject: subject, sender: sender, since: since,
          before: before, unseen_only: unseen_only
        )
        uids = imap.uid_search(criteria)
        uids = uids.reverse
        page = uids[0, limit] || []
        return [] if page.empty?

        # BODY.PEEK[] (no \Seen) so search results carry the same decoded snippet
        # as inbox(); search shares parse_envelope and therefore the item shape.
        envelopes = imap.uid_fetch(page, ["ENVELOPE", "FLAGS", "BODY.PEEK[]"])
        # uid_fetch returns rows in SERVER (ascending) order however the uids
        # were asked for, so the newest-first page above was silently re-sorted
        # and inbox(limit: 1) handed back the OLDEST message. Selection was
        # right; presentation was not. Restore the requested order.
        by_uid = (envelopes || []).each_with_object({}) { |m, h| h[m.attr["UID"]] = m }
        page.filter_map { |uid| by_uid[uid] }.map { |msg| parse_envelope(msg) }
      rescue *IMAP_CONNECTION_ERRORS => e
        raise imap_fail("search", e)
      ensure
        imap_cleanup(imap)
      end
    end

    # List all IMAP folders.
    #
    # Raises Tina4::MessengerConnectionError on a connection/protocol failure.
    def folders
      imap = imap_open("folders")
      begin
        boxes = imap.list("", "*")
        (boxes || []).map(&:name)
      rescue *IMAP_CONNECTION_ERRORS => e
        raise imap_fail("folders", e)
      ensure
        imap_cleanup(imap)
      end
    end

    # Mark a message as read (set \Seen flag).
    #
    # @param uid [String, Integer] message UID
    # @param folder [String] IMAP folder name
    def mark_read(uid, folder: "INBOX")
      imap_connect do |imap|
        imap.select(folder)
        imap.uid_store(uid.to_i, "+FLAGS", [:Seen])
      end
    rescue => e
      Tina4::Log.error("IMAP mark_read failed: #{e.message}")
    end

    # Mark a message as unread (clear \Seen flag). Mirror of mark_read; same
    # result-style error handling (logs, returns nil) — the two are a matched
    # pair of idempotent flag toggles.
    #
    # @param uid [String, Integer] message UID
    # @param folder [String] IMAP folder name
    def mark_unread(uid, folder: "INBOX")
      imap_connect do |imap|
        imap.select(folder)
        imap.uid_store(uid.to_i, "-FLAGS", [:Seen])
      end
    rescue => e
      Tina4::Log.error("IMAP mark_unread failed: #{e.message}")
    end

    # Delete a message: flag it \Deleted and expunge. Destructive, so it FAILS
    # LOUD — a connection/protocol failure raises MessengerConnectionError rather
    # than silently reporting success (parity with the Python master, which also
    # raises). Returns true when the expunge completes.
    #
    # @param uid [String, Integer] message UID
    # @param folder [String] IMAP folder name
    def delete(uid, folder: "INBOX")
      imap = imap_open("delete")
      begin
        imap.select(folder)
        imap.uid_store(uid, "+FLAGS", [:Deleted])
        imap.expunge
        true
      rescue *IMAP_CONNECTION_ERRORS => e
        raise imap_fail("delete", e)
      ensure
        imap_cleanup(imap)
      end
    end

    # Test IMAP connectivity without reading messages.
    #
    # @return [Hash] { success: Boolean, message: String }
    def test_imap_connection
      imap_connect do |_imap|
        # Connection succeeded
      end
      { success: true, message: "Connected to #{@imap_host}:#{@imap_port}" }
    rescue => e
      { success: false, message: "IMAP connection failed: #{e.message}" }
    end

    private

    # ── SMTP helpers ─────────────────────────────────────────────────────

    def auth_method
      return :plain if @username && @password

      nil
    end

    def normalize_recipients(value)
      case value
      when nil then []
      when String then [value]
      when Array then value.flatten.compact
      else [value.to_s]
      end
    end

    # Parse TINA4_MAIL_REDIRECT_TO (MAIL-DEC-01): comma-separated addresses,
    # each trimmed, blanks dropped. Empty/unset -> [] (redirect off, no
    # behaviour change).
    def parse_mail_redirect_list(raw)
      return [] if raw.nil? || raw.empty?

      raw.split(",").map(&:strip).reject(&:empty?)
    end

    def format_address(address, name = nil)
      if name && !name.empty?
        "#{name} <#{address}>"
      else
        address
      end
    end

    def build_message(to:, subject:, body:, html:, text: nil, cc:, bcc:, reply_to:,
                      attachments:, headers:, message_id:)
      boundary = "----=_Tina4_#{SecureRandom.hex(16)}"
      alt_boundary = "----=_Tina4Alt_#{SecureRandom.hex(16)}"
      date = Time.now.strftime("%a, %d %b %Y %H:%M:%S %z")
      has_text_alt = !text.nil? && html

      parts = []
      parts << "From: #{format_address(@from_address, @from_name)}"
      parts << "To: #{Array(to).join(', ')}"
      parts << "Cc: #{Array(cc).join(', ')}" unless Array(cc).empty?
      parts << "Subject: #{encode_header(subject)}"
      parts << "Date: #{date}"
      parts << "Message-ID: #{message_id}"
      parts << "MIME-Version: 1.0"
      parts << "Reply-To: #{reply_to}" if reply_to

      headers.each { |k, v| parts << "#{k}: #{v}" }

      if !attachments.empty?
        parts << "Content-Type: multipart/mixed; boundary=\"#{boundary}\""
        parts << ""
        parts << "--#{boundary}"

        # Body part (with optional text alternative)
        if has_text_alt
          parts << "Content-Type: multipart/alternative; boundary=\"#{alt_boundary}\""
          parts << ""
          parts << "--#{alt_boundary}"
          parts << "Content-Type: text/plain; charset=UTF-8"
          parts << "Content-Transfer-Encoding: base64"
          parts << ""
          parts << Base64.encode64(text)
          parts << "--#{alt_boundary}"
          parts << "Content-Type: text/html; charset=UTF-8"
          parts << "Content-Transfer-Encoding: base64"
          parts << ""
          parts << Base64.encode64(body)
          parts << "--#{alt_boundary}--"
        else
          content_type = html ? "text/html" : "text/plain"
          parts << "Content-Type: #{content_type}; charset=UTF-8"
          parts << "Content-Transfer-Encoding: base64"
          parts << ""
          parts << Base64.encode64(body)
        end

        # Attachment parts
        attachments.each do |attachment|
          parts << "--#{boundary}"
          parts.concat(build_attachment_part(attachment))
        end
        parts << "--#{boundary}--"
      elsif has_text_alt
        # Text alternative without attachments
        parts << "Content-Type: multipart/alternative; boundary=\"#{alt_boundary}\""
        parts << ""
        parts << "--#{alt_boundary}"
        parts << "Content-Type: text/plain; charset=UTF-8"
        parts << "Content-Transfer-Encoding: base64"
        parts << ""
        parts << Base64.encode64(text)
        parts << "--#{alt_boundary}"
        parts << "Content-Type: text/html; charset=UTF-8"
        parts << "Content-Transfer-Encoding: base64"
        parts << ""
        parts << Base64.encode64(body)
        parts << "--#{alt_boundary}--"
      else
        content_type = html ? "text/html" : "text/plain"
        parts << "Content-Type: #{content_type}; charset=UTF-8"
        parts << "Content-Transfer-Encoding: base64"
        parts << ""
        parts << Base64.encode64(body)
      end

      parts.join("\r\n")
    end

    def build_attachment_part(attachment)
      lines = []
      if attachment.is_a?(Hash)
        filename = attachment[:filename] || attachment[:name] || "attachment"
        content = attachment[:content] || ""
        mime = attachment[:mime_type] || attachment[:content_type] || "application/octet-stream"
      elsif attachment.is_a?(String) && File.exist?(attachment)
        filename = File.basename(attachment)
        content = File.binread(attachment)
        mime = guess_mime_type(filename)
      else
        return []
      end

      encoded = content.is_a?(String) && !content.ascii_only? ? Base64.encode64(content) : Base64.encode64(content.to_s)

      lines << "Content-Type: #{mime}; name=\"#{filename}\""
      lines << "Content-Disposition: attachment; filename=\"#{filename}\""
      lines << "Content-Transfer-Encoding: base64"
      lines << ""
      lines << encoded
      lines
    end

    def encode_header(value)
      if value.ascii_only?
        value
      else
        "=?UTF-8?B?#{Base64.strict_encode64(value)}?="
      end
    end

    def guess_mime_type(filename)
      ext = File.extname(filename).downcase
      {
        ".txt"  => "text/plain",
        ".html" => "text/html",
        ".htm"  => "text/html",
        ".css"  => "text/css",
        ".js"   => "application/javascript",
        ".json" => "application/json",
        ".xml"  => "application/xml",
        ".pdf"  => "application/pdf",
        ".zip"  => "application/zip",
        ".gz"   => "application/gzip",
        ".tar"  => "application/x-tar",
        ".png"  => "image/png",
        ".jpg"  => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".gif"  => "image/gif",
        ".svg"  => "image/svg+xml",
        ".csv"  => "text/csv",
        ".doc"  => "application/msword",
        ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".xls"  => "application/vnd.ms-excel",
        ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      }.fetch(ext, "application/octet-stream")
    end

    # ── IMAP helpers ─────────────────────────────────────────────────────

    # Open and authenticate an IMAP connection. On a connection/auth/protocol
    # failure this FAILS LOUD — logs and raises MessengerConnectionError —
    # rather than swallowing the error into an empty result.
    def imap_open(method)
      imap = Net::IMAP.new(@imap_host, port: @imap_port, ssl: @imap_use_tls)
      imap.login(@imap_username, @imap_password)
      imap
    rescue *IMAP_CONNECTION_ERRORS => e
      raise imap_fail(method, e)
    end

    # Best-effort teardown of an IMAP connection. Never raises.
    def imap_cleanup(imap)
      return if imap.nil?

      begin
        imap.logout
      rescue StandardError
        # ignore — already closing
      end
      begin
        imap.disconnect
      rescue StandardError
        # ignore — already closed
      end
    end

    # Log an IMAP connection/protocol failure and return the error to raise.
    # A genuinely empty mailbox is NOT an error and never reaches here.
    # Re-raises a MessengerError as-is; otherwise wraps in
    # MessengerConnectionError. Callers do `raise imap_fail(name, exc)`.
    def imap_fail(method, exc)
      Tina4::Log.error(
        "Messenger IMAP #{method}() failed: #{exc.class}: #{exc.message}"
      )
      return exc if exc.is_a?(MessengerError)

      MessengerConnectionError.new("IMAP #{method} failed: #{exc.message}")
    end

    # Connect, yield, then tear down — used by the mutators / connectivity test
    # that keep their own result-style error handling (mark_read,
    # test_imap_connection). Read methods use imap_open + ensure directly so
    # they can fail loud.
    def imap_connect(&block)
      imap = Net::IMAP.new(@imap_host, port: @imap_port, ssl: @imap_use_tls)
      imap.login(@imap_username, @imap_password)
      result = block.call(imap)
      imap.logout
      imap.disconnect
      result
    end

    # An inbox() item — EXACTLY these seven keys (decisions doc G4):
    #   uid:String, subject, from:String, to:String, date:ISO-8601, snippet, seen:Boolean
    # from/to are header STRINGS ("Name <email>"), NOT arrays of {name,email};
    # date is ISO-8601; snippet is decoded/transfer-decoded/tag-stripped plain
    # text (<= 200 chars); seen is a Boolean. No flags/size.
    def parse_envelope(fetch_data)
      env = fetch_data.attr["ENVELOPE"]
      flags = fetch_data.attr["FLAGS"] || []
      raw_body = fetch_data.attr["BODY[]"] || ""

      {
        # String in all four frameworks. Ruby alone returned Integer, so
        # `uid == "3"` was false here and true everywhere else.
        uid: fetch_data.attr.keys.include?("UID") ? fetch_data.attr["UID"].to_s : nil,
        subject: env.subject ? decode_mime_header(env.subject) : "",
        from: format_address_string(env.from),
        to: format_address_string(env.to),
        date: format_date_iso8601(env.date),
        snippet: build_snippet(raw_body),
        seen: flags.include?(:Seen)
      }
    end

    # A read() item (decisions doc G5) — EXACTLY these 10 keys: uid, subject,
    # from/to/cc (header STRINGS), date, body_text/body_html (was body/html),
    # attachments, headers (the full header Hash). Message-ID lives in
    # headers["Message-ID"], never a top-level key. Each attachments item is
    # {filename, content_type, size, content} — content is the RAW DECODED BYTES
    # of the part (issue #69), so an attachment is downloadable straight from
    # read() and size is that byte length.
    def parse_full_message(fetch_data)
      env = fetch_data.attr["ENVELOPE"]
      raw_body = fetch_data.attr["BODY[]"] || ""

      body_text, body_html = extract_body_parts(raw_body)

      {
        uid: fetch_data.attr.keys.include?("UID") ? fetch_data.attr["UID"].to_s : nil,
        subject: env.subject ? decode_mime_header(env.subject) : "",
        from: format_address_string(env.from),
        to: format_address_string(env.to),
        cc: format_address_string(env.cc),
        date: format_date_iso8601(env.date),
        body_text: body_text,
        body_html: body_html,
        attachments: extract_attachments(raw_body),
        headers: parse_headers(raw_body)
      }
    end

    # Format an ENVELOPE address list into the header STRING shape the other three
    # frameworks return: "Name <email>" per address (bare "email" when unnamed),
    # comma-joined. Empty string when there are no addresses.
    def format_address_string(addresses)
      return "" if addresses.nil? || addresses.empty?

      addresses.map do |addr|
        email = "#{addr.mailbox}@#{addr.host}"
        name = addr.name && !addr.name.to_s.empty? ? decode_mime_header(addr.name) : nil
        name ? "#{name} <#{email}>" : email
      end.join(", ")
    end

    # ISO-8601 string from an ENVELOPE date. Mirrors Python's
    # parsedate_to_datetime(...).isoformat(): parse the RFC5322 date and emit
    # ISO-8601; fall back to the raw value on a parse failure, "" when absent.
    def format_date_iso8601(raw)
      return "" if raw.nil? || raw.to_s.strip.empty?

      begin
        Time.parse(raw.to_s).iso8601
      rescue ArgumentError, TypeError
        raw.to_s
      end
    end

    # Decoded, transfer-decoded, tag-stripped, whitespace-collapsed plain text,
    # truncated to 200 chars — the settled snippet shape (G3). Reuses the
    # existing multipart/transfer-decoding; prefers the text part, falls back to
    # the HTML part with its tags stripped.
    def build_snippet(raw_body)
      text, html = extract_body_parts(raw_body.to_s)
      source = text.nil? || text.empty? ? html.to_s : text
      plain = source.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
      plain.length > 200 ? plain[0, 200] : plain
    end

    # Attachments parsed from a raw MIME message: an array of
    # {filename, content_type, size, content}. A part is an attachment when it
    # carries a Content-Disposition of attachment. content is the RAW DECODED
    # BYTES of the part (transfer-decoded, binary encoding — the same convention
    # as request.files' "content"), so an attachment is downloadable straight
    # from read() (issue #69); size is that byte length. [] when the message is
    # not multipart or has no attachment parts.
    def extract_attachments(raw)
      raw = raw.to_s
      return [] unless raw =~ %r{Content-Type:\s*multipart/\w+;\s*boundary="?([^"\s;]+)"?}i

      boundary = Regexp.last_match(1)
      raw.split("--#{boundary}").each_with_object([]) do |part, acc|
        next unless part =~ /Content-Disposition:\s*attachment/i

        filename = part[/filename="?([^"\r\n;]+)"?/i, 1] ||
                   part[/name="?([^"\r\n;]+)"?/i, 1] || "attachment"
        content_type = part[%r{Content-Type:\s*([^\s;]+)}i, 1] || "application/octet-stream"
        content = extract_part_bytes(part)
        acc << {
          filename: filename.strip,
          content_type: content_type.strip,
          size: content.bytesize,
          content: content
        }
      end
    end

    # Parse the top-level RFC5322 header block of a raw message into a Hash
    # (name => value). Mirrors Python's dict(msg.items()); a repeated header keeps
    # the last value; folded continuation lines are unfolded.
    def parse_headers(raw)
      header_block = raw.to_s.split(/\r?\n\r?\n/, 2).first.to_s
      headers = {}
      current_key = nil
      header_block.each_line do |raw_line|
        line = raw_line.chomp
        if current_key && line =~ /\A[ \t]/
          headers[current_key] = "#{headers[current_key]} #{line.strip}"
        elsif (m = line.match(/\A([\w!\#$%&'*+\-.^_`|~]+):[ \t]?(.*)\z/))
          current_key = m[1]
          headers[current_key] = m[2]
        end
      end
      headers
    end

    def decode_mime_header(value)
      return "" if value.nil?

      value.gsub(/=\?([^?]+)\?([BbQq])\?([^?]+)\?=/) do
        charset = Regexp.last_match(1)
        encoding = Regexp.last_match(2).upcase
        encoded = Regexp.last_match(3)

        decoded = case encoding
                  when "B"
                    Base64.decode64(encoded)
                  when "Q"
                    encoded.gsub("_", " ").gsub(/=([0-9A-Fa-f]{2})/) { [$1].pack("H2") }
                  else
                    encoded
                  end

        decoded.force_encoding(charset).encode("UTF-8", invalid: :replace, undef: :replace)
      end
    end

    def extract_body_parts(raw)
      text_body = nil
      html_body = nil

      # Check for multipart
      if raw =~ /Content-Type:\s*multipart\/\w+;\s*boundary="?([^"\s;]+)"?/i
        boundary = Regexp.last_match(1)
        parts = raw.split("--#{boundary}")
        parts.each do |part|
          next if part.strip == "" || part.strip == "--"

          if part =~ /Content-Type:\s*text\/plain/i
            text_body = extract_part_body(part)
          elsif part =~ /Content-Type:\s*text\/html/i
            html_body = extract_part_body(part)
          end
        end
      elsif raw =~ /Content-Type:\s*text\/html/i
        html_body = extract_part_body(raw)
      else
        text_body = extract_part_body(raw)
      end

      [text_body || "", html_body || ""]
    end

    def extract_part_body(part)
      # Split headers from body at double CRLF or double LF
      header_body = part.split(/\r?\n\r?\n/, 2)
      return "" unless header_body.length > 1

      body = header_body[1].strip
      headers = header_body[0]

      if headers =~ /Content-Transfer-Encoding:\s*base64/i
        Base64.decode64(body).force_encoding("UTF-8")
      elsif headers =~ /Content-Transfer-Encoding:\s*quoted-printable/i
        body.gsub(/=\r?\n/, "").gsub(/=([0-9A-Fa-f]{2})/) { [$1].pack("H2") }
      else
        body
      end
    end

    # The RAW DECODED BYTES of a MIME part: transfer-decoded (base64 /
    # quoted-printable → the original bytes) in BINARY (ASCII-8BIT) encoding, so a
    # non-text attachment (image, PDF, zip) round-trips byte-for-byte. This is the
    # attachment analogue of extract_part_body, which force-encodes UTF-8 for the
    # text/HTML BODIES and strips them; an attachment must stay raw, unstripped
    # bytes, so the two are kept separate rather than shared. tina4: if a third
    # raw-part reader appears, fold the shared "split headers/body + read
    # Content-Transfer-Encoding" step into one helper the two call with different
    # post-decode handling.
    def extract_part_bytes(part)
      header_body = part.to_s.split(/\r?\n\r?\n/, 2)
      return "".b unless header_body.length > 1

      headers = header_body[0]
      # The single CRLF immediately before the next boundary delimiter is MIME
      # framing, not payload, so drop it before decoding (Python's
      # get_payload(decode=True) drops it too). base64 decoding ignores it
      # anyway; quoted-printable and raw 7bit/8bit would otherwise keep it.
      body = header_body[1].sub(/\r?\n\z/, "")

      if headers =~ /Content-Transfer-Encoding:\s*base64/i
        Base64.decode64(body)
      elsif headers =~ /Content-Transfer-Encoding:\s*quoted-printable/i
        body.gsub(/=\r?\n/, "").gsub(/=([0-9A-Fa-f]{2})/) { [$1].pack("H2") }.b
      else
        # 7bit/8bit/none: the part body IS the bytes.
        body.b
      end
    end

    def build_search_criteria(subject:, sender:, since:, before:, unseen_only:)
      criteria = []
      criteria.push("SUBJECT", subject) if subject
      criteria.push("FROM", sender) if sender
      criteria.push("SINCE", format_imap_date(since)) if since
      criteria.push("BEFORE", format_imap_date(before)) if before
      criteria << "UNSEEN" if unseen_only
      criteria << "ALL" if criteria.empty?
      criteria
    end

    def format_imap_date(date)
      case date
      when Time, DateTime
        date.strftime("%d-%b-%Y")
      when Date
        date.strftime("%d-%b-%Y")
      when String
        date
      else
        date.to_s
      end
    end
  end

end
