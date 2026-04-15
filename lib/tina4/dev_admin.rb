# frozen_string_literal: true

require "json"
require "digest"
require "tmpdir"
require "net/http"
require "uri"
require_relative "metrics"

module Tina4
  # Thread-safe in-memory message log for dev dashboard
  class MessageLog
    Entry = Struct.new(:timestamp, :category, :level, :message, keyword_init: true)

    def initialize
      @entries = []
      @mutex = Mutex.new
    end

    def log(category, level, message)
      @mutex.synchronize do
        @entries << Entry.new(
          timestamp: Time.now.utc.iso8601(3),
          category: category.to_s,
          level: level.to_s.upcase,
          message: message.to_s
        )
        # Keep last 500 entries
        @entries.shift if @entries.size > 500
      end
    end

    def get(category: nil)
      @mutex.synchronize do
        list = category ? @entries.select { |e| e.category == category.to_s } : @entries.dup
        list.reverse.map { |e| { timestamp: e.timestamp, category: e.category, level: e.level, message: e.message } }
      end
    end

    def clear(category: nil)
      @mutex.synchronize do
        if category
          @entries.reject! { |e| e.category == category.to_s }
        else
          @entries.clear
        end
      end
    end

    def count
      @mutex.synchronize do
        counts = Hash.new(0)
        @entries.each { |e| counts[e.category] += 1 }
        counts["total"] = @entries.size
        counts
      end
    end
  end

  # Thread-safe request capture for dev dashboard
  class RequestInspector
    CapturedRequest = Struct.new(:timestamp, :method, :path, :status, :duration, keyword_init: true)

    def initialize
      @requests = []
      @mutex = Mutex.new
    end

    def capture(method:, path:, status:, duration:)
      @mutex.synchronize do
        @requests << CapturedRequest.new(
          timestamp: Time.now.utc.iso8601(3),
          method: method.to_s,
          path: path.to_s,
          status: status.to_i,
          duration: duration.to_f.round(3)
        )
        # Keep last 200 entries
        @requests.shift if @requests.size > 200
      end
    end

    def get(limit: 50)
      @mutex.synchronize do
        @requests.last([limit, @requests.size].min).reverse.map do |r|
          { timestamp: r.timestamp, method: r.method, path: r.path, status: r.status, duration_ms: r.duration }
        end
      end
    end

    def stats
      @mutex.synchronize do
        return { total: 0, avg_ms: 0.0, errors: 0, slowest_ms: 0.0 } if @requests.empty?

        durations = @requests.map(&:duration)
        error_count = @requests.count { |r| r.status >= 400 }

        {
          total: @requests.size,
          avg_ms: (durations.sum / durations.size).round(2),
          errors: error_count,
          slowest_ms: durations.max.round(2)
        }
      end
    end

    def clear
      @mutex.synchronize { @requests.clear }
    end
  end

  # Thread-safe, file-persisted error tracker for the dev dashboard Error Tracker panel.
  #
  # Errors are stored in a JSON file in the system temp directory keyed by
  # project path, so they survive across requests and server restarts.
  # Duplicate errors (same type + message + file + line) are de-duplicated —
  # the count increments and the entry is re-opened if it was resolved.
  class ErrorTracker
    MAX_ERRORS = 200
    private_constant :MAX_ERRORS

    def initialize
      @mutex  = Mutex.new
      @errors = nil  # lazy-loaded
      @registered = false
      @store_path = File.join(
        Dir.tmpdir,
        "tina4_dev_errors_#{Digest::MD5.hexdigest(Dir.pwd)}.json"
      )
    end

    # Capture a Ruby error / exception into the tracker.
    # @param error_type [String]  e.g. "RuntimeError" or "NoMethodError"
    # @param message    [String]  exception message
    # @param traceback  [String]  formatted backtrace (optional)
    # @param file       [String]  source file (optional)
    # @param line       [Integer] source line (optional)
    def capture(error_type:, message:, traceback: "", file: "", line: 0)
      @mutex.synchronize do
        load_unlocked
        fingerprint = Digest::MD5.hexdigest("#{error_type}|#{message}|#{file}|#{line}")
        now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

        if @errors.key?(fingerprint)
          @errors[fingerprint][:count]    += 1
          @errors[fingerprint][:last_seen] = now
          @errors[fingerprint][:resolved]  = false  # re-open resolved duplicates
        else
          @errors[fingerprint] = {
            id:          fingerprint,
            error_type:  error_type,
            message:     message,
            traceback:   traceback,
            file:        file,
            line:        line,
            first_seen:  now,
            last_seen:   now,
            count:       1,
            resolved:    false
          }
        end
        save_unlocked
      end
    end

    # Capture a Ruby exception object directly.
    def capture_exception(exc)
      capture(
        error_type: exc.class.name,
        message:    exc.message,
        traceback:  (exc.backtrace || []).first(20).join("\n"),
        file:       (exc.backtrace_locations&.first&.path || ""),
        line:       (exc.backtrace_locations&.first&.lineno || 0)
      )
    end

    # Return all errors (newest first).
    # @param include_resolved [Boolean]
    def get(include_resolved: true)
      @mutex.synchronize do
        load_unlocked
        entries = @errors.values
        entries = entries.reject { |e| e[:resolved] } unless include_resolved
        entries.sort_by { |e| e[:last_seen] }.reverse
      end
    end

    # Count of unresolved errors.
    def unresolved_count
      @mutex.synchronize do
        load_unlocked
        @errors.count { |_, e| !e[:resolved] }
      end
    end

    # Health summary (matches Python BrokenTracker interface).
    def health
      @mutex.synchronize do
        load_unlocked
        total    = @errors.size
        resolved = @errors.count { |_, e| e[:resolved] }
        unresolved = total - resolved
        { total: total, unresolved: unresolved, resolved: resolved, healthy: unresolved.zero? }
      end
    end

    # Mark a single error as resolved.
    def resolve(id)
      @mutex.synchronize do
        load_unlocked
        return false unless @errors.key?(id)

        @errors[id][:resolved] = true
        save_unlocked
        true
      end
    end

    # Remove all resolved errors.
    def clear_resolved
      @mutex.synchronize do
        load_unlocked
        @errors.reject! { |_, e| e[:resolved] }
        save_unlocked
      end
    end

    # Remove ALL errors.
    def clear_all
      @mutex.synchronize do
        @errors = {}
        save_unlocked
      end
    end

    # Register Ruby error handlers to feed the tracker.
    # Installs an at_exit hook that captures unhandled exceptions.
    # Safe to call multiple times — only registers once.
    def register
      return if @registered

      @registered = true
      tracker = self
      at_exit do
        if (exc = $!) && !exc.is_a?(SystemExit)
          tracker.capture_exception(exc)
        end
      end
    end

    # Reset (for testing).
    def reset!
      @mutex.synchronize do
        @errors = {}
        @registered = false
        File.delete(@store_path) if File.exist?(@store_path)
      end
    end

    private

    def load_unlocked
      return if @errors

      if File.exist?(@store_path)
        raw = File.read(@store_path) rescue nil
        data = raw ? (JSON.parse(raw, symbolize_names: true) rescue nil) : nil
        if data.is_a?(Array)
          # Re-key by id
          @errors = {}
          data.each { |e| @errors[e[:id]] = e if e[:id] }
        else
          @errors = {}
        end
      else
        @errors = {}
      end
    end

    def save_unlocked
      # Trim to max, keeping newest last_seen
      if @errors.size > MAX_ERRORS
        sorted = @errors.values.sort_by { |e| e[:last_seen] }.last(MAX_ERRORS)
        @errors = {}
        sorted.each { |e| @errors[e[:id]] = e }
      end

      File.write(@store_path, JSON.generate(@errors.values))
    rescue StandardError
      # Best-effort persistence — never raise in a tracker
    end
  end

  # Developer dashboard module - only active in debug mode
  module DevAdmin
    class << self
      def message_log
        @message_log ||= MessageLog.new
      end

      def request_inspector
        @request_inspector ||= RequestInspector.new
      end

      def mailbox
        @mailbox ||= DevMailbox.new
      end

      def error_tracker
        @error_tracker ||= ErrorTracker.new
      end

      def enabled?
        Tina4::Env.is_truthy(ENV["TINA4_DEBUG"])
      end

      # Handle a /__dev request; returns [status, headers, body] or nil if not a dev path
      def handle_request(env)
        return nil unless enabled?

        path = env["PATH_INFO"] || "/"
        method = env["REQUEST_METHOD"]

        case [method, path]
        when ["GET", "/__dev"], ["GET", "/__dev/"]
          serve_dashboard
        when ["GET", "/__dev/js/tina4-dev-admin.min.js"]
          serve_dev_js
        when ["GET", "/__dev/api/mtime"]
          json_response({ mtime: @reload_mtime || 0, file: @reload_file || "" })
        when ["POST", "/__dev/api/reload"]
          body = read_json_body(env) || {}
          @reload_mtime = Time.now.to_i
          @reload_file = body["file"] || ""
          reload_type = body["type"] || "reload"
          Tina4::Log.info("External reload trigger: #{reload_type}#{@reload_file.empty? ? '' : " (#{@reload_file})"}")
          json_response({ ok: true, type: reload_type })
        when ["GET", "/__dev/api/status"]
          json_response(status_payload)
        when ["GET", "/__dev/api/routes"]
          json_response(routes_payload)
        when ["GET", "/__dev/api/messages"]
          category = query_param(env, "category")
          messages = message_log.get(category: category)
          counts = message_log.count
          json_response({ messages: messages, counts: counts })
        when ["POST", "/__dev/api/messages/clear"]
          body = read_json_body(env)
          category = body["category"] if body
          message_log.clear(category: category)
          json_response({ cleared: true })
        when ["GET", "/__dev/api/requests"]
          limit = (query_param(env, "limit") || 50).to_i
          json_response({ requests: request_inspector.get(limit: limit), stats: request_inspector.stats })
        when ["POST", "/__dev/api/requests/clear"]
          request_inspector.clear
          json_response({ cleared: true })
        when ["GET", "/__dev/api/system"]
          json_response(system_payload)
        when ["GET", "/__dev/api/queue/topics"]
          queue_dir = File.join(Dir.pwd, "data", "queue")
          topics = Dir.exist?(queue_dir) ? Dir.children(queue_dir).select { |d| File.directory?(File.join(queue_dir, d)) }.sort : []
          topics = ["default"] if topics.empty?
          json_response({ topics: topics })
        when ["GET", "/__dev/api/queue/dead-letters"]
          topic = query_param(env, "topic") || "default"
          jobs = []
          begin
            queue = Tina4::Queue.new(backend: :file, topic: topic) if defined?(Tina4::Queue)
            jobs = queue.respond_to?(:dead_letters) ? queue.dead_letters.map { |j| j.merge(status: "dead_letter") } : []
          rescue StandardError => e
            jobs = []
          end
          json_response({ jobs: jobs, count: jobs.size, topic: topic })
        when ["GET", "/__dev/api/queue"]
          topic = query_param(env, "topic") || "default"
          stats = { pending: 0, completed: 0, failed: 0, reserved: 0 }
          jobs = []
          begin
            if defined?(Tina4::Queue)
              queue = Tina4::Queue.new(backend: :file, topic: topic)
              stats = {
                pending: queue.respond_to?(:size) ? queue.size("pending") : 0,
                completed: queue.respond_to?(:size) ? queue.size("completed") : 0,
                failed: queue.respond_to?(:size) ? queue.size("failed") : 0,
                reserved: queue.respond_to?(:size) ? queue.size("reserved") : 0,
              }
              jobs.concat(queue.failed.map { |j| j.merge(status: "failed") }) if queue.respond_to?(:failed)
              jobs.concat(queue.dead_letters.map { |j| j.merge(status: "dead_letter") }) if queue.respond_to?(:dead_letters)
            end
          rescue StandardError => e
            # fall through to empty stats
          end
          json_response({ jobs: jobs, stats: stats })
        when ["GET", "/__dev/api/mailbox"]
          messages = mailbox.inbox
          json_response({ messages: messages, count: messages.size, unread: mailbox.unread_count })
        when ["GET", "/__dev/api/broken"]
          errors   = error_tracker.get(include_resolved: true)
          h        = error_tracker.health
          json_response({ errors: errors, count: errors.size, health: h })
        when ["POST", "/__dev/api/broken/resolve"]
          body = read_json_body(env)
          id   = body && body["id"]
          resolved = id ? error_tracker.resolve(id) : false
          json_response({ resolved: resolved, id: id })
        when ["POST", "/__dev/api/broken/clear"]
          error_tracker.clear_resolved
          json_response({ cleared: true })
        when ["GET", "/__dev/api/websockets"]
          json_response({ connections: [], count: 0 })
        when ["POST", "/__dev/api/websockets/disconnect"]
          body = read_json_body(env)
          # TODO: disconnect WS connection by id from body["id"]
          json_response({ disconnected: true })
        when ["GET", "/__dev/api/mailbox/read"]
          message_id = query_param(env, "id")
          message = mailbox.read(message_id)
          if message
            json_response(message)
          else
            body = JSON.generate({ error: "Message not found", id: message_id })
            [404, { "content-type" => "application/json; charset=utf-8" }, [body]]
          end
        when ["POST", "/__dev/api/mailbox/seed"]
          body = read_json_body(env)
          count = ((body && body["count"]) || 5).to_i
          mailbox.seed(count: count)
          json_response({ seeded: count })
        when ["POST", "/__dev/api/mailbox/clear"]
          mailbox.clear
          json_response({ cleared: true })
        when ["GET", "/__dev/api/messages/search"]
          keyword = query_param(env, "q") || query_param(env, "keyword") || ""
          all_messages = message_log.get
          filtered = keyword.empty? ? all_messages : all_messages.select { |m| m[:message].to_s.downcase.include?(keyword.downcase) }
          json_response({ messages: filtered, count: filtered.size, keyword: keyword })
        when ["POST", "/__dev/api/queue/retry"]
          body = read_json_body(env)
          # TODO: retry failed jobs by id from body["id"]
          json_response({ retried: true })
        when ["POST", "/__dev/api/queue/purge"]
          # TODO: purge completed jobs
          json_response({ purged: true })
        when ["POST", "/__dev/api/queue/replay"]
          body = read_json_body(env)
          # TODO: replay a specific job by id from body["id"]
          json_response({ replayed: true })
        when ["GET", "/__dev/api/table"]
          table_name = query_param(env, "name")
          json_response(table_detail_payload(table_name))
        when ["POST", "/__dev/api/seed"]
          body = read_json_body(env)
          table_name = (body && body["table"]) || ""
          count = (body && body["count"]) || 10
          json_response(seed_table_data(table_name, count.to_i))
        when ["POST", "/__dev/api/tool"]
          body = read_json_body(env)
          tool = (body && body["tool"]) || ""
          json_response(run_tool(tool))
        when ["POST", "/__dev/api/chat"]
          body = read_json_body(env)
          message = (body && body["message"]) || ""
          json_response({
            reply: "Chat is not yet connected to an AI backend. You said: \"#{message}\"",
            timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
          })
        when ["GET", "/__dev/api/connections"]
          handle_connections_get
        when ["POST", "/__dev/api/connections/test"]
          body = read_json_body(env)
          handle_connections_test(body)
        when ["POST", "/__dev/api/connections/save"]
          body = read_json_body(env)
          handle_connections_save(body)
        when ["POST", "/__dev/api/query"]
          body = read_json_body(env)
          sql = (body && (body["query"] || body["sql"])) || ""
          json_response(run_query(sql))
        when ["GET", "/__dev/api/tables"]
          json_response(tables_payload)
        when ["GET", "/__dev/api/gallery"]
          json_response(gallery_list)
        when ["POST", "/__dev/api/gallery/deploy"]
          body = read_json_body(env)
          name = (body && body["name"]) || ""
          json_response(gallery_deploy(name))
        when ["GET", "/__dev/api/version-check"]
          json_response(version_check_payload)
        when ["GET", "/__dev/api/metrics"]
          json_response(Tina4::Metrics.quick_metrics)
        when ["GET", "/__dev/api/metrics/full"]
          json_response(Tina4::Metrics.full_analysis)
        when ["GET", "/__dev/api/metrics/file"]
          file_path = (query_param(env, "path") || "").to_s
          json_response(Tina4::Metrics.file_detail(file_path))
        when ["GET", "/__dev/api/graphql/schema"]
          begin
            gql = Tina4::GraphQL.new
            # Auto-discover and register all ORM subclasses
            ObjectSpace.each_object(Class).select { |c| c < Tina4::ORM }.each do |model_class|
              gql.from_orm(model_class.new)
            end
            json_response({ schema: gql.introspect, sdl: gql.schema_sdl })
          rescue => e
            json_response({ error: e.message }, 400)
          end
        else
          nil
        end
      end


      private

      def query_param(env, key)
        qs = env["QUERY_STRING"] || ""
        params = URI.decode_www_form(qs).to_h rescue {}
        params[key]
      end

      def read_json_body(env)
        input = env["rack.input"]
        return nil unless input
        input.rewind if input.respond_to?(:rewind)
        raw = input.read
        return nil if raw.nil? || raw.empty?
        JSON.parse(raw) rescue nil
      end

      def json_response(data)
        body = JSON.generate(data)
        [200, { "content-type" => "application/json; charset=utf-8" }, [body]]
      end

      def version_check_payload
        current = Tina4::VERSION
        latest = current
        begin
          uri = URI.parse("https://rubygems.org/api/v1/versions/tina4ruby/latest.json")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 5
          http.read_timeout = 5
          req = Net::HTTP::Get.new(uri)
          resp = http.request(req)
          if resp.is_a?(Net::HTTPSuccess)
            data = JSON.parse(resp.body)
            latest = data["version"] || current
          end
        rescue StandardError
          # Offline or timeout — return current as latest
        end
        { current: current, latest: latest }
      end

      def serve_dashboard
        spa = '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Tina4 Dev Admin</title></head><body><div id="app" data-framework="ruby" data-color="#ef4444"></div><script src="/__dev/js/tina4-dev-admin.min.js"></script></body></html>'
        [200, { "content-type" => "text/html; charset=utf-8" }, [spa]]
      end

      def serve_dev_js
        js_path = File.join(File.dirname(__FILE__), "public", "js", "tina4-dev-admin.min.js")
        if File.file?(js_path)
          [200, { "content-type" => "application/javascript; charset=utf-8" }, [File.read(js_path)]]
        else
          [404, { "content-type" => "text/plain" }, ["tina4-dev-admin.min.js not found"]]
        end
      end

      def status_payload
        db_table_count = 0
        begin
          db = Tina4.database
          db_table_count = db.tables.size if db
        rescue
          # ignore
        end

        {
          framework: "tina4-ruby",
          version: Tina4::VERSION,
          ruby_version: RUBY_VERSION,
          platform: RUBY_PLATFORM,
          debug: ENV["TINA4_DEBUG"] || "false",
          log_level: ENV["TINA4_LOG_LEVEL"] || "ERROR",
          database: ENV["DATABASE_URL"] || "not configured",
          db_tables: db_table_count,
          uptime: (Time.now - (defined?(@boot_time) && @boot_time ? @boot_time : (@boot_time = Time.now))).round(1),
          route_count: Tina4::Router.routes.size,
          request_stats: request_inspector.stats,
          message_counts: message_log.count,
          health: error_tracker.health
        }
      end

      def routes_payload
        internal_prefixes = ["/__dev", "/health", "/swagger"]
        routes = Tina4::Router.routes
          .reject { |route| internal_prefixes.any? { |prefix| route.path.start_with?(prefix) } }
          .map do |route|
          handler_name = ""
          mod = ""
          if route.handler.is_a?(Proc)
            source = route.handler.source_location
            if source
              handler_name = "#{File.basename(source[0])}:#{source[1]}"
              mod = File.dirname(source[0])
            end
          end
          {
            method: route.method,
            pattern: route.path,
            path: route.path,
            middleware: route.respond_to?(:middleware_count) ? route.middleware_count : 0,
            cache: route.respond_to?(:cached?) ? route.cached? : false,
            secure: !route.auth_handler.nil?,
            auth_required: !route.auth_handler.nil?,
            handler: handler_name,
            module: mod
          }
        end
        { routes: routes, count: routes.size }
      end

      def system_payload
        gc = GC.stat
        mem = begin
          if RUBY_PLATFORM.include?("darwin")
            `ps -o rss= -p #{Process.pid}`.strip.to_i # KB
          elsif RUBY_PLATFORM.include?("linux")
            (File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i rescue 0)
          else
            0
          end
        end

        os_release = (`uname -r`.strip rescue "unknown")
        host_name = (`hostname`.strip rescue "unknown")

        {
          ruby_version: RUBY_VERSION,
          ruby_engine: RUBY_ENGINE,
          os: "#{RUBY_PLATFORM} #{os_release}",
          architecture: RUBY_PLATFORM,
          memory: {
            current_mb: (mem / 1024.0).round(1),
            peak_mb: "N/A",
            limit: "N/A"
          },
          server: {
            software: "Ruby/WEBrick",
            hostname: host_name,
            document_root: Tina4.root_dir || Dir.pwd
          },
          framework: {
            name: "tina4-ruby",
            version: Tina4::VERSION,
            route_count: Tina4::Router.routes.size
          },
          extensions: $LOADED_FEATURES.map { |f| File.basename(f, ".rb") }.uniq.sort.first(50),
          gc: {
            count: gc[:count],
            heap_allocated_pages: gc[:heap_allocated_pages],
            heap_live_slots: gc[:heap_live_slots],
            total_allocated_objects: gc[:total_allocated_objects],
            total_freed_objects: gc[:total_freed_objects]
          },
          pid: Process.pid,
          thread_count: Thread.list.size,
          env: ENV["TINA4_ENV"] || ENV["RACK_ENV"] || ENV["RUBY_ENV"] || "development",
          db_tables: (begin; db = Tina4.database; db ? db.tables.size : 0; rescue; 0; end),
          db_connected: (begin; db = Tina4.database; !db.nil?; rescue; false; end)
        }
      end

      def run_tool(tool)
        output = case tool
                 when "routes"
                   routes = Tina4::Router.routes.map { |r| { method: r.method, path: r.path } }
                   JSON.pretty_generate(routes)
                 when "test"
                   "Test runner not yet configured. Run: bundle exec rspec"
                 when "migrate"
                   "Migration runner not yet configured. Run: tina4ruby migrate"
                 when "seed"
                   "Seeder not yet configured. Run: tina4ruby seed"
                 else
                   "Unknown tool: #{tool}"
                 end
        { tool: tool, output: output }
      end

      def run_query(sql)
        sql = sql.to_s.strip
        return { error: "No SQL provided" } if sql.empty?

        db = Tina4.database
        return { error: "No database configured" } unless db

        # Split multiple statements on semicolons
        statements = sql.split(";").map(&:strip).reject(&:empty?)

        begin
          if statements.size == 1
            first_word = statements[0].split(/[\s\t\n\r]+/, 2).first.to_s.upcase
            if %w[SELECT PRAGMA EXPLAIN SHOW DESCRIBE].include?(first_word)
              result = db.fetch(statements[0])
              rows = result.respond_to?(:to_a) ? result.to_a : (result.is_a?(Array) ? result : [])
              columns = rows.first.is_a?(Hash) ? rows.first.keys.map(&:to_s) : []
              return { columns: columns, rows: rows, count: rows.size }
            end
          end

          # Execute all statements (single write or multi-statement batch)
          total_affected = 0
          statements.each do |stmt|
            result = db.execute(stmt)
            if result == false
              return { error: db.get_error || "Statement failed: #{stmt}" }
            end
            total_affected += (result.respond_to?(:affected_rows) ? result.affected_rows : 0)
          end

          { affected: total_affected, success: true }
        rescue => e
          { error: e.message }
        end
      end

      def tables_payload
        db = Tina4.database
        return { error: "No database configured", tables: [] } unless db

        begin
          table_list = db.tables
          { tables: table_list }
        rescue => e
          { error: e.message, tables: [] }
        end
      end

      def table_detail_payload(table_name)
        return { error: "No table name provided" } if table_name.nil? || table_name.strip.empty?

        db = Tina4.database
        return { error: "No database configured" } unless db

        begin
          columns = db.columns(table_name)
          result = db.fetch("SELECT * FROM #{table_name} LIMIT 20")
          rows = result.respond_to?(:to_a) ? result.to_a : (result.is_a?(Array) ? result : [])
          { table: table_name, columns: columns, rows: rows, count: rows.size }
        rescue => e
          { error: e.message }
        end
      end

      def seed_table_data(table_name, count)
        return { error: "No table name provided" } if table_name.nil? || table_name.strip.empty?

        db = Tina4.database
        return { error: "No database configured" } unless db

        begin
          columns = db.columns(table_name)
          seeded = Tina4.seed_table(table_name, columns, count: count)
          { table: table_name, seeded: seeded }
        rescue => e
          { error: e.message }
        end
      end

      def handle_connections_get
        env_path = File.join(Dir.pwd, ".env")
        url = ""
        username = ""
        password = ""
        if File.file?(env_path)
          File.readlines(env_path).each do |line|
            line = line.strip
            next if line.empty? || line.start_with?("#") || !line.include?("=")
            key, val = line.split("=", 2)
            key = key.strip
            val = (val || "").strip.gsub(/\A["']|["']\z/, "")
            case key
            when "DATABASE_URL" then url = val
            when "DATABASE_USERNAME" then username = val
            when "DATABASE_PASSWORD" then password = val.empty? ? "" : "***"
            end
          end
        end
        json_response({ url: url, username: username, password: password })
      end

      def handle_connections_test(body)
        url = (body && body["url"]) || ""
        username = (body && body["username"]) || ""
        password = (body && body["password"]) || ""
        return json_response({ success: false, error: "No connection URL provided" }) if url.empty?
        begin
          db = Tina4::Database.new(url, username: username, password: password)
          version = "Connected"
          table_count = 0
          begin
            tables = db.tables
            table_count = tables.is_a?(Array) ? tables.size : 0
          rescue => e
            table_count = 0
          end
          begin
            url_lower = url.downcase
            if url_lower.include?("sqlite")
              row = db.fetch_one("SELECT sqlite_version() as v")
              version = "SQLite #{row && row[:v] || row && row['v']}" if row
            elsif url_lower.include?("postgres")
              row = db.fetch_one("SELECT version() as v")
              version = (row && (row[:v] || row["v"]) || "PostgreSQL").to_s.split(",").first if row
            elsif url_lower.include?("mysql")
              row = db.fetch_one("SELECT version() as v")
              version = "MySQL #{row && row[:v] || row && row['v']}" if row
            elsif url_lower.include?("mssql") || url_lower.include?("sqlserver")
              row = db.fetch_one("SELECT @@VERSION as v")
              version = (row && (row[:v] || row["v"]) || "MSSQL").to_s.split("\n").first if row
            elsif url_lower.include?("firebird")
              row = db.fetch_one("SELECT rdb$get_context('SYSTEM', 'ENGINE_VERSION') as v FROM rdb$database")
              version = "Firebird #{row && row[:v] || row && row['v']}" if row
            end
          rescue => e
            # Keep version as "Connected"
          end
          db.close if db.respond_to?(:close)
          json_response({ success: true, version: version, tables: table_count })
        rescue => e
          json_response({ success: false, error: e.message })
        end
      end

      def handle_connections_save(body)
        url = (body && body["url"]) || ""
        username = (body && body["username"]) || ""
        password = (body && body["password"]) || ""
        return json_response({ success: false, error: "No connection URL provided" }) if url.empty?
        begin
          env_path = File.join(Dir.pwd, ".env")
          lines = File.file?(env_path) ? File.readlines(env_path, chomp: true) : []
          keys_found = { "DATABASE_URL" => false, "DATABASE_USERNAME" => false, "DATABASE_PASSWORD" => false }
          new_lines = []
          lines.each do |line|
            stripped = line.strip
            if stripped.empty? || stripped.start_with?("#") || !stripped.include?("=")
              new_lines << line
              next
            end
            key = stripped.split("=", 2).first.strip
            case key
            when "DATABASE_URL"
              new_lines << "DATABASE_URL=#{url}"
              keys_found["DATABASE_URL"] = true
            when "DATABASE_USERNAME"
              new_lines << "DATABASE_USERNAME=#{username}"
              keys_found["DATABASE_USERNAME"] = true
            when "DATABASE_PASSWORD"
              new_lines << "DATABASE_PASSWORD=#{password}"
              keys_found["DATABASE_PASSWORD"] = true
            else
              new_lines << line
            end
          end
          values = { "DATABASE_URL" => url, "DATABASE_USERNAME" => username, "DATABASE_PASSWORD" => password }
          keys_found.each do |key, found|
            new_lines << "#{key}=#{values[key]}" unless found
          end
          File.write(env_path, new_lines.join("\n") + "\n")
          json_response({ success: true })
        rescue => e
          json_response({ success: false, error: e.message })
        end
      end

      def gallery_list
        gallery_dir = File.join(File.dirname(__FILE__), "gallery")
        items = []
        if Dir.exist?(gallery_dir)
          Dir.children(gallery_dir).sort.each do |entry|
            entry_path = File.join(gallery_dir, entry)
            meta_file = File.join(entry_path, "meta.json")
            next unless File.directory?(entry_path) && File.file?(meta_file)

            meta = JSON.parse(File.read(meta_file)) rescue next
            meta["id"] = entry
            src_dir = File.join(entry_path, "src")
            if Dir.exist?(src_dir)
              meta["files"] = Dir.glob(File.join(src_dir, "**", "*"))
                                 .select { |f| File.file?(f) }
                                 .map { |f| f.sub("#{src_dir}/", "") }
            end
            items << meta
          end
        end
        { gallery: items, count: items.size }
      end

      def gallery_deploy(name)
        return { error: "No gallery item specified" } if name.to_s.empty?

        gallery_src = File.join(File.dirname(__FILE__), "gallery", name, "src")
        return { error: "Gallery item '#{name}' not found" } unless Dir.exist?(gallery_src)

        require "fileutils"
        project_src = File.join(Tina4.root_dir || Dir.pwd, "src")
        copied = []
        Dir.glob(File.join(gallery_src, "**", "*")).each do |src_file|
          next unless File.file?(src_file)

          rel = src_file.sub("#{gallery_src}/", "")
          dest = File.join(project_src, rel)
          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(src_file, dest)
          copied << rel
        end

        # Re-discover routes so new files are immediately available
        begin
          routes_dir = File.join(Tina4.root_dir || Dir.pwd, "src", "routes")
          Tina4::Router.load_routes(routes_dir) if Dir.exist?(routes_dir)
        rescue => e
          Tina4::Log.warning("Gallery route reload: #{e.message}")
        end

        { deployed: name, files: copied }
      end
    end
  end
end
