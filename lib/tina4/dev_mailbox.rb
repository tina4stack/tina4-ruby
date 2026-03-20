# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "fileutils"
require "base64"

module Tina4
  class DevMailbox
    attr_reader :mailbox_dir

    def initialize(mailbox_dir: nil)
      @mailbox_dir = mailbox_dir || ENV["TINA4_MAILBOX_DIR"] || "data/mailbox"
      ensure_dirs
    end

    # Capture an outgoing email to the local filesystem instead of sending
    def capture(to:, subject:, body:, html: false, cc: [], bcc: [],
                reply_to: nil, from_address: nil, from_name: nil, attachments: [])
      msg_id = SecureRandom.uuid
      timestamp = Time.now

      message = {
        id: msg_id,
        from: { name: from_name, email: from_address },
        to: normalize_recipients(to),
        cc: normalize_recipients(cc),
        bcc: normalize_recipients(bcc),
        reply_to: reply_to,
        subject: subject,
        body: body,
        html: html,
        attachments: store_attachments(msg_id, attachments),
        read: false,
        folder: "outbox",
        created_at: timestamp.iso8601,
        updated_at: timestamp.iso8601
      }

      write_message(msg_id, message)

      Tina4::Log.debug("DevMailbox captured email: #{subject} -> #{Array(to).join(', ')}")
      { success: true, message: "Email captured to dev mailbox", id: msg_id }
    end

    # List messages in the mailbox
    def inbox(limit: 50, offset: 0, folder: nil)
      messages = load_all_messages
      messages = messages.select { |m| m[:folder] == folder } if folder
      messages.sort_by { |m| m[:created_at] || "" }.reverse[offset, limit] || []
    end

    # Read a single message by ID
    def read(msg_id)
      path = message_path(msg_id)
      return nil unless File.exist?(path)

      message = JSON.parse(File.read(path), symbolize_names: true)
      unless message[:read]
        message[:read] = true
        message[:updated_at] = Time.now.iso8601
        File.write(path, JSON.pretty_generate(message))
      end
      message
    end

    # Count unread messages
    def unread_count
      load_all_messages.count { |m| m[:read] == false }
    end

    # Delete a message by ID
    def delete(msg_id)
      path = message_path(msg_id)
      return false unless File.exist?(path)

      File.delete(path)
      # Clean up attachments directory
      att_dir = File.join(@mailbox_dir, "attachments", msg_id)
      FileUtils.rm_rf(att_dir) if Dir.exist?(att_dir)
      true
    end

    # Clear all messages, optionally by folder
    def clear(folder: nil)
      if folder
        load_all_messages.each do |msg|
          delete(msg[:id]) if msg[:folder] == folder
        end
      else
        messages_dir = File.join(@mailbox_dir, "messages")
        FileUtils.rm_rf(messages_dir)
        FileUtils.rm_rf(File.join(@mailbox_dir, "attachments"))
        ensure_dirs
      end
    end

    # Seed the mailbox with sample messages for development
    def seed(count: 5)
      fake = Tina4::FakeData.new
      count.times do |i|
        name = fake.name
        email = fake.email(from_name: name)
        capture(
          to: "dev@localhost",
          subject: fake.sentence(words: 4 + rand(4)),
          body: Array.new(2 + rand(3)) { fake.sentence(words: 8 + rand(8)) }.join("\n\n"),
          html: i.even?,
          from_address: email,
          from_name: name
        )
      end
      Tina4::Log.info("DevMailbox seeded with #{count} messages")
    end

    # Count messages by folder
    # Returns { inbox: N, outbox: N, total: N }
    def count(folder: nil)
      messages = load_all_messages
      if folder
        n = messages.count { |m| m[:folder] == folder }
        { folder.to_sym => n, total: n }
      else
        inbox_count = messages.count { |m| m[:folder] == "inbox" }
        outbox_count = messages.count { |m| m[:folder] == "outbox" }
        { inbox: inbox_count, outbox: outbox_count, total: messages.length }
      end
    end

    private

    def ensure_dirs
      FileUtils.mkdir_p(File.join(@mailbox_dir, "messages"))
      FileUtils.mkdir_p(File.join(@mailbox_dir, "attachments"))
    end

    def message_path(msg_id)
      File.join(@mailbox_dir, "messages", "#{msg_id}.json")
    end

    def write_message(msg_id, message)
      File.write(message_path(msg_id), JSON.pretty_generate(message))
    end

    def load_all_messages
      pattern = File.join(@mailbox_dir, "messages", "*.json")
      Dir.glob(pattern).filter_map do |path|
        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError => e
        Tina4::Log.error("DevMailbox: corrupt message file #{path}: #{e.message}")
        nil
      end
    end

    def normalize_recipients(value)
      case value
      when nil then []
      when String then [value]
      when Array then value.flatten.compact
      else [value.to_s]
      end
    end

    def store_attachments(msg_id, attachments)
      return [] if attachments.nil? || attachments.empty?

      att_dir = File.join(@mailbox_dir, "attachments", msg_id)
      FileUtils.mkdir_p(att_dir)

      attachments.map do |attachment|
        if attachment.is_a?(Hash)
          filename = attachment[:filename] || attachment[:name] || "attachment"
          content = attachment[:content] || ""
          mime = attachment[:mime_type] || attachment[:content_type] || "application/octet-stream"
        elsif attachment.is_a?(String) && File.exist?(attachment)
          filename = File.basename(attachment)
          content = File.binread(attachment)
          mime = "application/octet-stream"
        else
          next nil
        end

        file_path = File.join(att_dir, filename)
        File.binwrite(file_path, content)

        { filename: filename, mime_type: mime, size: content.bytesize, path: file_path }
      end.compact
    end
  end
end
