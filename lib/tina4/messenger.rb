# frozen_string_literal: true

require "net/smtp"
require "net/imap"
require "base64"
require "securerandom"
require "time"

module Tina4
  class Messenger
    attr_reader :host, :port, :username, :from_address, :from_name,
                :imap_host, :imap_port, :use_tls

    # Initialize with SMTP config, falls back to ENV vars
    def initialize(host: nil, port: nil, username: nil, password: nil,
                   from_address: nil, from_name: nil, use_tls: true,
                   imap_host: nil, imap_port: nil)
      @host         = host         || ENV["SMTP_HOST"] || "localhost"
      @port         = (port        || ENV["SMTP_PORT"] || 587).to_i
      @username     = username     || ENV["SMTP_USERNAME"]
      @password     = password     || ENV["SMTP_PASSWORD"]
      @from_address = from_address || ENV["SMTP_FROM"] || @username
      @from_name    = from_name    || ENV["SMTP_FROM_NAME"] || ""
      @use_tls      = use_tls
      @imap_host    = imap_host    || ENV["IMAP_HOST"] || @host
      @imap_port    = (imap_port   || ENV["IMAP_PORT"] || 993).to_i
    end

    # Send email using Ruby's Net::SMTP
    # Returns { success: true/false, message: "...", id: "..." }
    def send(to:, subject:, body:, html: false, cc: [], bcc: [],
             reply_to: nil, attachments: [], headers: {})
      message_id = "<#{SecureRandom.uuid}@#{@host}>"
      raw = build_message(
        to: to, subject: subject, body: body, html: html,
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

    # List messages in a folder
    def inbox(folder: "INBOX", limit: 20, offset: 0)
      imap_connect do |imap|
        imap.select(folder)
        uids = imap.uid_search(["ALL"])
        uids = uids.reverse # newest first
        page = uids[offset, limit] || []
        return [] if page.empty?

        envelopes = imap.uid_fetch(page, ["ENVELOPE", "FLAGS", "RFC822.SIZE"])
        (envelopes || []).map { |msg| parse_envelope(msg) }
      end
    rescue => e
      Tina4::Log.error("IMAP inbox failed: #{e.message}")
      []
    end

    # Read a single message by UID
    def read(uid, folder: "INBOX", mark_read: true)
      imap_connect do |imap|
        imap.select(folder)
        data = imap.uid_fetch(uid, ["ENVELOPE", "FLAGS", "BODY[]", "RFC822.SIZE"])
        return nil if data.nil? || data.empty?

        if mark_read
          imap.uid_store(uid, "+FLAGS", [:Seen])
        end

        msg = data.first
        parse_full_message(msg)
      end
    rescue => e
      Tina4::Log.error("IMAP read failed: #{e.message}")
      nil
    end

    # Count unread messages
    def unread(folder: "INBOX")
      imap_connect do |imap|
        imap.select(folder)
        uids = imap.uid_search(["UNSEEN"])
        uids.length
      end
    rescue => e
      Tina4::Log.error("IMAP unread count failed: #{e.message}")
      0
    end

    # Search messages with filters
    def search(folder: "INBOX", subject: nil, sender: nil, since: nil,
               before: nil, unseen_only: false, limit: 20)
      imap_connect do |imap|
        imap.select(folder)
        criteria = build_search_criteria(
          subject: subject, sender: sender, since: since,
          before: before, unseen_only: unseen_only
        )
        uids = imap.uid_search(criteria)
        uids = uids.reverse
        page = uids[0, limit] || []
        return [] if page.empty?

        envelopes = imap.uid_fetch(page, ["ENVELOPE", "FLAGS", "RFC822.SIZE"])
        (envelopes || []).map { |msg| parse_envelope(msg) }
      end
    rescue => e
      Tina4::Log.error("IMAP search failed: #{e.message}")
      []
    end

    # List all IMAP folders
    def folders
      imap_connect do |imap|
        boxes = imap.list("", "*")
        (boxes || []).map(&:name)
      end
    rescue => e
      Tina4::Log.error("IMAP folders failed: #{e.message}")
      []
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

    def format_address(address, name = nil)
      if name && !name.empty?
        "#{name} <#{address}>"
      else
        address
      end
    end

    def build_message(to:, subject:, body:, html:, cc:, bcc:, reply_to:,
                      attachments:, headers:, message_id:)
      boundary = "----=_Tina4_#{SecureRandom.hex(16)}"
      date = Time.now.strftime("%a, %d %b %Y %H:%M:%S %z")

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

      if attachments.empty?
        content_type = html ? "text/html" : "text/plain"
        parts << "Content-Type: #{content_type}; charset=UTF-8"
        parts << "Content-Transfer-Encoding: base64"
        parts << ""
        parts << Base64.encode64(body)
      else
        parts << "Content-Type: multipart/mixed; boundary=\"#{boundary}\""
        parts << ""
        # Body part
        content_type = html ? "text/html" : "text/plain"
        parts << "--#{boundary}"
        parts << "Content-Type: #{content_type}; charset=UTF-8"
        parts << "Content-Transfer-Encoding: base64"
        parts << ""
        parts << Base64.encode64(body)
        # Attachment parts
        attachments.each do |attachment|
          parts << "--#{boundary}"
          parts.concat(build_attachment_part(attachment))
        end
        parts << "--#{boundary}--"
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

    def imap_connect(&block)
      imap = Net::IMAP.new(@imap_host, port: @imap_port, ssl: @use_tls)
      imap.login(@username, @password)
      result = block.call(imap)
      imap.logout
      imap.disconnect
      result
    end

    def parse_envelope(fetch_data)
      env = fetch_data.attr["ENVELOPE"]
      flags = fetch_data.attr["FLAGS"] || []
      size = fetch_data.attr["RFC822.SIZE"] || 0

      {
        uid: fetch_data.attr.keys.include?("UID") ? fetch_data.attr["UID"] : nil,
        subject: env.subject ? decode_mime_header(env.subject) : "",
        from: format_imap_address(env.from),
        to: format_imap_address(env.to),
        date: env.date,
        flags: flags.map(&:to_s),
        read: flags.include?(:Seen),
        size: size
      }
    end

    def parse_full_message(fetch_data)
      env = fetch_data.attr["ENVELOPE"]
      flags = fetch_data.attr["FLAGS"] || []
      raw_body = fetch_data.attr["BODY[]"] || ""

      body_text, body_html = extract_body_parts(raw_body)

      {
        uid: fetch_data.attr.keys.include?("UID") ? fetch_data.attr["UID"] : nil,
        subject: env.subject ? decode_mime_header(env.subject) : "",
        from: format_imap_address(env.from),
        to: format_imap_address(env.to),
        cc: format_imap_address(env.cc),
        date: env.date,
        message_id: env.message_id,
        flags: flags.map(&:to_s),
        read: flags.include?(:Seen),
        body: body_text,
        html: body_html,
        raw: raw_body
      }
    end

    def format_imap_address(addresses)
      return [] if addresses.nil?

      addresses.map do |addr|
        email = "#{addr.mailbox}@#{addr.host}"
        if addr.name && !addr.name.empty?
          { name: decode_mime_header(addr.name), email: email }
        else
          { name: nil, email: email }
        end
      end
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

  # Factory: returns a DevMailbox-intercepting messenger in dev mode,
  # or a real Messenger in production.
  def self.create_messenger(**options)
    dev_mode = ENV["TINA4_DEBUG_LEVEL"]&.include?("DEBUG") ||
               ENV["TINA4_DEBUG_LEVEL"]&.include?("ALL") ||
               ENV["TINA4_DEV"] == "true"

    smtp_configured = ENV["SMTP_HOST"] && !ENV["SMTP_HOST"].empty?

    if dev_mode && !smtp_configured
      mailbox_dir = options.delete(:mailbox_dir) || ENV["TINA4_MAILBOX_DIR"]
      mailbox = DevMailbox.new(mailbox_dir: mailbox_dir)
      DevMessengerProxy.new(mailbox, **options)
    else
      Messenger.new(**options)
    end
  end

  # Proxy that wraps DevMailbox with the same interface as Messenger#send
  class DevMessengerProxy
    attr_reader :mailbox

    def initialize(mailbox, **options)
      @mailbox = mailbox
      @from_address = options[:from_address] || ENV["SMTP_FROM"] || "dev@localhost"
      @from_name    = options[:from_name]    || ENV["SMTP_FROM_NAME"] || "Dev Mailer"
    end

    def send(to:, subject:, body:, html: false, cc: [], bcc: [],
             reply_to: nil, attachments: [], headers: {})
      @mailbox.capture(
        to: to, subject: subject, body: body, html: html,
        cc: cc, bcc: bcc, reply_to: reply_to,
        from_address: @from_address, from_name: @from_name,
        attachments: attachments
      )
    end

    def test_connection
      { success: true, message: "DevMailbox mode — no SMTP connection needed" }
    end

    def inbox(**args)  = @mailbox.inbox(**args)
    def read(...)      = @mailbox.read(...)
    def unread(...)    = @mailbox.unread_count
    def search(**args) = @mailbox.inbox(**args)
    def folders        = ["inbox", "outbox"]
  end
end
