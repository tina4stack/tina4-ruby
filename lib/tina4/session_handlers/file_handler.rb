# frozen_string_literal: true
require "json"
require "fileutils"
require "digest"

module Tina4
  module SessionHandlers
    class FileHandler
      # TINA4_SESSION_PATH selects the session directory, with the SAME
      # precedence the other three frameworks use: an explicit option wins, then
      # the environment, then "data/sessions".
      #
      # Ruby read NO env var here and hard-defaulted to <cwd>/sessions, so it
      # drifted on BOTH halves of ADR-0024: the documented variable did nothing
      # (example/.env.example has advertised "TINA4_SESSION_PATH=data/sessions"
      # the whole time), and the default location differed from Python
      # (session/__init__.py FileSessionHandler), PHP (Session.php:128) and Node
      # (session.ts:184) - all three of which resolve
      # `path || TINA4_SESSION_PATH || "data/sessions"`. Pointing the file
      # backend at a mounted volume worked in three frameworks and was silently
      # ignored in the fourth, which is the exact "one env var and nothing else"
      # promise ADR-0024 makes.
      #
      # The default stays RELATIVE, exactly as the other three leave it, so all
      # four resolve the same path against the same working directory.
      def initialize(options = {})
        @dir = options[:dir] || ENV["TINA4_SESSION_PATH"] || File.join("data", "sessions")
        # TINA4_SESSION_TTL is the ONE session-lifetime variable, and it must
        # reach EVERY backend (ADR-0024). This used to be a hard-coded 86400,
        # so an operator setting a 15-minute session got 24 hours here and got
        # it right only on memcached - the one handler that read the variable.
        # 3600 is the default in Python (the master), PHP and Node.
        @ttl = (options[:ttl] || ENV["TINA4_SESSION_TTL"] || 3600).to_i
        FileUtils.mkdir_p(@dir)
      end

      def read(session_id)
        path = session_path(session_id)
        return nil unless File.exist?(path)

        stored = JSON.parse(File.read(path))
        if expired?(stored, path)
          File.delete(path)
          return nil
        end

        unwrap(stored)
      rescue JSON::ParserError
        nil
      end

      # Write session data.
      #
      # The ttl is consumed HERE, at write time, and baked into an ABSOLUTE
      # deadline stored beside the payload, so nothing at read time needs to know
      # what the ttl was. That is what makes a per-call ttl durable: a reader with
      # a different ttl can no longer judge someone else's record.
      #
      # A ttl of 0 (or negative) means NEVER EXPIRES, matching the Python master,
      # Node, and every mainstream implementation measured. It previously fell
      # through to the mtime comparison, where `mtime + 0 < Time.now` made ttl: 0
      # mean "expire immediately" - the opposite meaning, and the only backend in
      # any of the four frameworks that read it that way.
      #
      # @param session_id [String] the session id
      # @param data [Hash] the payload to store
      # @param ttl [Integer] per-call lifetime in seconds; 0 uses the handler default
      def write(session_id, data, ttl = 0)
        effective_ttl = ttl.to_i.positive? ? ttl.to_i : @ttl
        expires_at = effective_ttl.positive? ? Time.now.to_f + effective_ttl : 0.0
        File.write(
          session_path(session_id),
          JSON.generate({ "_data" => data, "_expires" => expires_at })
        )
      end

      def destroy(session_id)
        path = session_path(session_id)
        File.delete(path) if File.exist?(path)
      end

      def cleanup
        sweep
      end

      # Garbage-collect expired sessions. Matches the Python interface.
      # @param max_age [Integer] accepted for interface parity; expiry is absolute
      #   and already baked into the stored deadline, so it is used only for legacy
      #   records that carry no deadline of their own.
      def gc(max_age = nil)
        sweep(max_age)
      end

      private

      # Delete every genuinely-expired record. An absent or zero deadline means
      # never expires, so such a record is never a sweep candidate.
      def sweep(max_age = nil)
        return unless Dir.exist?(@dir)

        Dir.glob(File.join(@dir, "sess_*")).each do |file|
          stored = begin
            JSON.parse(File.read(file))
          rescue JSON::ParserError
            nil
          end
          File.delete(file) if stored && expired?(stored, file, max_age)
        rescue StandardError
          # Corrupt or locked file - skip
        end
      end

      # Decide whether a stored record has expired.
      #
      # THE CONTRACT: an ABSENT or ZERO deadline means "never expires". It is
      # guarded OUT of the comparison, never fed INTO it. Verified against real
      # mainstream implementations - PHP's native files handler, express-session,
      # Django, Laravel, connect-redis and connect-mongo - none of which deletes a
      # record carrying no expiry.
      #
      # A LEGACY record (a bare payload written before the envelope existed) has no
      # deadline of its own, so it keeps the original mtime comparison. Without
      # that fallback every already-stored session would become immortal on
      # upgrade, which trades data loss for a security bug.
      def expired?(stored, path, max_age = nil)
        if stored.is_a?(Hash) && stored.key?("_expires")
          expires_at = stored["_expires"].to_f
          return expires_at.positive? && expires_at < Time.now.to_f
        end

        lifetime = (max_age || @ttl).to_i
        lifetime.positive? && File.mtime(path) + lifetime < Time.now
      end

      # Return the caller's payload. A legacy bare payload is returned as-is, so a
      # record written by an older version still reads correctly.
      def unwrap(stored)
        return stored["_data"] if stored.is_a?(Hash) && stored.key?("_expires")

        stored
      end

      # SHA-256 of the id. A session id can therefore never become a path
      # component, AND two distinct ids can never collide.
      #
      # The previous gsub(/[^a-zA-Z0-9_-]/, "") was traversal-safe but LOSSY: it
      # collapsed "a/b" and "ab" onto the same sess_ab.json, so two different
      # sessions shared one record and one user's data surfaced under another
      # user's id. Parity with the Python master's FileSessionHandler._file
      # (hashlib.sha256(session_id.encode()).hexdigest()).
      #
      # The sess_ prefix is kept deliberately so #cleanup and #gc keep matching
      # with their Dir.glob("sess_*").
      def session_path(session_id)
        File.join(@dir, "sess_#{Digest::SHA256.hexdigest(session_id.to_s)}.json")
      end
    end
  end
end
