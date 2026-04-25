# frozen_string_literal: true

require "json"
require "digest"
require "tmpdir"
require "net/http"
require "uri"
require "fileutils"
require "shellwords"
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

      # Write `.tina4/mcp.json` so MCP-aware tools (Claude Code, Cursor) can
      # auto-discover this project's live docs server. Idempotent — no-op if
      # the file already matches the desired contents. Also appends `.tina4/`
      # to the project's `.gitignore` if a git repo is present.
      def auto_discover_mcp!(project_root: Dir.pwd)
        return if @_mcp_auto_discovered
        @_mcp_auto_discovered = true
        return unless enabled?

        port = ENV["TINA4_PORT"] || ENV["PORT"] || "7147"
        url  = "http://localhost:#{port}/__dev/api/mcp"
        target_dir = File.join(project_root, ".tina4")
        target = File.join(target_dir, "mcp.json")
        payload = {
          "mcpServers" => {
            "tina4-live-docs" => {
              "url" => url,
              "description" => "Live API docs for this Tina4 project (framework + user code)",
            },
          },
        }
        begin
          FileUtils.mkdir_p(target_dir)
          existing = if File.file?(target)
                       (JSON.parse(File.read(target)) rescue {})
                     else
                       {}
                     end
          if existing != payload
            File.write(target, JSON.pretty_generate(payload))
          end

          gitignore = File.join(project_root, ".gitignore")
          if File.directory?(File.join(project_root, ".git"))
            current = File.file?(gitignore) ? File.read(gitignore) : ""
            unless current.lines.map(&:strip).include?(".tina4/") || current.lines.map(&:strip).include?(".tina4")
              prefix = (!current.empty? && !current.end_with?("\n")) ? "\n" : ""
              File.write(gitignore, "#{current}#{prefix}.tina4/\n")
            end
          end
        rescue StandardError => e
          Tina4::Log.warning("auto_discover_mcp! failed: #{e.message}") if defined?(Tina4::Log)
        end
      end

      # Handle a /__dev request; returns [status, headers, body] or nil if not a dev path
      def handle_request(env)
        return nil unless enabled?
        auto_discover_mcp!

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
          # "Clear All" button — flush every tracked error, not only the
          # ones individually marked resolved. Matches PHP/Python.
          error_tracker.clear_all
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
        when ["GET", "/__dev/api/thoughts"]
          json_response(thoughts_payload)
        when ["POST", "/__dev/api/supervise/create"]
          body = read_json_body(env) || {}
          json_response(proxy_supervisor("/supervise/create", method: "POST", body: body))
        when ["GET", "/__dev/api/supervise/sessions"]
          json_response(proxy_supervisor("/supervise/sessions", method: "GET", query: env["QUERY_STRING"]))
        when ["GET", "/__dev/api/supervise/diff"]
          json_response(proxy_supervisor("/supervise/diff", method: "GET", query: env["QUERY_STRING"]))
        when ["POST", "/__dev/api/supervise/commit"]
          body = read_json_body(env) || {}
          json_response(proxy_supervisor("/supervise/commit", method: "POST", body: body))
        when ["POST", "/__dev/api/supervise/cancel"]
          body = read_json_body(env) || {}
          json_response(proxy_supervisor("/supervise/cancel", method: "POST", body: body))
        when ["POST", "/__dev/api/execute"]
          body = read_json_body(env) || {}
          execute_proxy(body)
        when ["GET", "/__dev/api/files"]
          json_response(files_list(env))
        when ["GET", "/__dev/api/file"]
          json_response(file_read_payload(query_param(env, "path")))
        when ["GET", "/__dev/api/file/raw"]
          file_raw_response(query_param(env, "path"))
        when ["POST", "/__dev/api/file/save"]
          body = read_json_body(env) || {}
          json_response(file_save(body))
        when ["POST", "/__dev/api/file/rename"]
          body = read_json_body(env) || {}
          json_response(file_rename(body))
        when ["POST", "/__dev/api/file/delete"]
          body = read_json_body(env) || {}
          json_response(file_delete(body))
        when ["GET", "/__dev/api/deps/search"]
          json_response(deps_search(query_param(env, "q") || query_param(env, "query") || ""))
        when ["POST", "/__dev/api/deps/install"]
          body = read_json_body(env) || {}
          json_response(deps_install(body))
        when ["GET", "/__dev/api/git/status"]
          json_response(git_status_payload)
        when ["GET", "/__dev/api/mcp/tools"]
          json_response(mcp_tools_list)
        when ["POST", "/__dev/api/mcp/call"]
          body = read_json_body(env) || {}
          json_response(mcp_tool_call(body))
        when ["GET", "/__dev/api/scaffold"]
          json_response(scaffold_templates)
        when ["POST", "/__dev/api/scaffold/run"]
          body = read_json_body(env) || {}
          json_response(scaffold_run(body))
        when ["GET", "/__dev/api/docs/search"]
          json_response(docs_search_payload(env))
        when ["GET", "/__dev/api/docs/class"]
          json_response(docs_class_payload(query_param(env, "name")))
        when ["GET", "/__dev/api/docs/method"]
          json_response(docs_method_payload(query_param(env, "class"), query_param(env, "name")))
        when ["GET", "/__dev/api/docs/index"]
          json_response(docs_index_payload(query_param(env, "source")))
        when ["GET", "/__dev/api/docs/.well-known.json"]
          json_response(docs_well_known_payload)
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

      # ── New dev-admin surface area (parity with Python/PHP) ────

      def supervisor_base
        base = ENV["TINA4_SUPERVISOR_URL"].to_s.strip
        return base unless base.empty?
        port = (ENV["TINA4_PORT"] || ENV["PORT"] || "7147").to_i + 2000
        "http://127.0.0.1:#{port}"
      end

      def thoughts_payload
        base = supervisor_base
        begin
          uri = URI.parse("#{base}/thoughts")
          req = Net::HTTP::Get.new(uri)
          resp = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) { |h| h.request(req) }
          return JSON.parse(resp.body) if resp.is_a?(Net::HTTPSuccess)
          { thoughts: [], error: "Supervisor returned #{resp.code}" }
        rescue StandardError => e
          { thoughts: [], error: e.message }
        end
      end

      def proxy_supervisor(path, method: "GET", body: nil, query: nil)
        base = supervisor_base
        url = "#{base}#{path}"
        url += "?#{query}" if query && !query.empty?
        begin
          uri = URI.parse(url)
          req = case method.upcase
                when "POST"
                  r = Net::HTTP::Post.new(uri)
                  r["Content-Type"] = "application/json"
                  r.body = JSON.generate(body || {})
                  r
                else
                  Net::HTTP::Get.new(uri)
                end
          resp = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 30) { |h| h.request(req) }
          begin
            JSON.parse(resp.body)
          rescue JSON::ParserError
            { body: resp.body, status: resp.code.to_i }
          end
        rescue StandardError => e
          { error: e.message, supervisor: base }
        end
      end

      def execute_proxy(body)
        # Proxy POST /execute to the supervisor at framework_port + 2000.
        # Pass through the response stream as-is (SSE or JSON).
        base = supervisor_base
        begin
          uri = URI.parse("#{base}/execute")
          req = Net::HTTP::Post.new(uri)
          req["Content-Type"] = "application/json"
          req["Accept"] = "text/event-stream"
          req.body = JSON.generate(body || {})
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 2
          http.read_timeout = 300
          resp = http.request(req)
          ct = resp["content-type"] || "application/json; charset=utf-8"
          [resp.code.to_i, { "content-type" => ct }, [resp.body.to_s]]
        rescue StandardError => e
          body_str = JSON.generate({ error: e.message, supervisor: base })
          [502, { "content-type" => "application/json; charset=utf-8" }, [body_str]]
        end
      end

      def safe_project_path(rel_path)
        root = File.expand_path(Dir.pwd)
        resolved = File.expand_path(rel_path.to_s, root)
        raise ArgumentError, "path escapes project directory" unless resolved.start_with?(root)
        resolved
      end

      def files_list(env)
        rel = query_param(env, "path") || "."
        begin
          target = safe_project_path(rel)
          return { error: "Not found" } unless File.exist?(target)
          return { error: "Not a directory" } unless File.directory?(target)
          entries = Dir.children(target).sort.map do |name|
            full = File.join(target, name)
            {
              name: name,
              type: File.directory?(full) ? "dir" : "file",
              size: File.file?(full) ? File.size(full) : 0
            }
          end
          { path: rel, entries: entries, count: entries.size }
        rescue => e
          { error: e.message }
        end
      end

      def file_read_payload(rel)
        return { error: "path required" } if rel.nil? || rel.empty?
        begin
          target = safe_project_path(rel)
          return { error: "Not found" } unless File.exist?(target)
          return { error: "Not a file" } unless File.file?(target)
          content = File.read(target, encoding: "utf-8", invalid: :replace, undef: :replace)
          { path: rel, content: content, bytes: File.size(target) }
        rescue => e
          { error: e.message }
        end
      end

      def file_raw_response(rel)
        return json_response({ error: "path required" }) if rel.nil? || rel.empty?
        begin
          target = safe_project_path(rel)
          return json_response({ error: "Not found" }) unless File.file?(target)
          content = File.binread(target)
          ct = case File.extname(target).downcase
               when ".css" then "text/css"
               when ".js"  then "application/javascript"
               when ".json" then "application/json"
               when ".html", ".htm" then "text/html"
               when ".png" then "image/png"
               when ".jpg", ".jpeg" then "image/jpeg"
               when ".gif" then "image/gif"
               when ".svg" then "image/svg+xml"
               else "text/plain; charset=utf-8"
               end
          [200, { "content-type" => ct }, [content]]
        rescue => e
          json_response({ error: e.message })
        end
      end

      def file_save(body)
        rel     = body["path"].to_s
        content = body["content"].to_s
        return { error: "path required" } if rel.empty?
        begin
          target = safe_project_path(rel)
          existed = File.exist?(target)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, content, encoding: "utf-8")
          Tina4::Plan.record_action(existed ? "patched" : "created", rel) if defined?(Tina4::Plan)
          { saved: rel, bytes: content.bytesize }
        rescue => e
          { error: e.message }
        end
      end

      def file_rename(body)
        from = body["from"].to_s
        to   = body["to"].to_s
        return { error: "from/to required" } if from.empty? || to.empty?
        begin
          src = safe_project_path(from)
          dst = safe_project_path(to)
          return { error: "Source not found" } unless File.exist?(src)
          FileUtils.mkdir_p(File.dirname(dst))
          File.rename(src, dst)
          { renamed: { from: from, to: to } }
        rescue => e
          { error: e.message }
        end
      end

      def file_delete(body)
        rel = body["path"].to_s
        return { error: "path required" } if rel.empty?
        begin
          target = safe_project_path(rel)
          return { error: "Not found" } unless File.exist?(target)
          if File.directory?(target)
            FileUtils.rm_rf(target)
          else
            File.delete(target)
          end
          { deleted: rel }
        rescue => e
          { error: e.message }
        end
      end

      def deps_search(query)
        return { results: [], count: 0, error: "query required" } if query.to_s.strip.empty?
        begin
          uri = URI.parse("https://rubygems.org/api/v1/search.json?query=#{URI.encode_www_form_component(query)}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 5
          http.read_timeout = 8
          resp = http.request(Net::HTTP::Get.new(uri))
          if resp.is_a?(Net::HTTPSuccess)
            gems = JSON.parse(resp.body)
            results = gems.first(20).map do |g|
              { name: g["name"], version: g["version"], info: g["info"].to_s[0, 200] }
            end
            { results: results, count: results.size }
          else
            { results: [], count: 0, error: "rubygems returned #{resp.code}" }
          end
        rescue => e
          { results: [], count: 0, error: e.message }
        end
      end

      def deps_install(body)
        name = body["name"].to_s.strip
        return { ok: false, error: "name required" } if name.empty?
        # Append to Gemfile if not present — do NOT actually bundle install.
        gemfile = File.join(Dir.pwd, "Gemfile")
        return { ok: false, error: "No Gemfile at project root" } unless File.exist?(gemfile)
        content = File.read(gemfile)
        if content.include?("gem \"#{name}\"") || content.include?("gem '#{name}'")
          return { ok: true, gem: name, note: "already in Gemfile" }
        end
        File.open(gemfile, "a") { |f| f.write("\ngem \"#{name}\"\n") }
        { ok: true, gem: name, note: "added to Gemfile; run `bundle install`" }
      end

      def git_status_payload
        begin
          inside = `cd #{Shellwords.escape(Dir.pwd)} && git rev-parse --is-inside-work-tree 2>/dev/null`.strip
          return { error: "Not a git repository" } if inside != "true"
          branch = `cd #{Shellwords.escape(Dir.pwd)} && git branch --show-current 2>/dev/null`.strip
          status = `cd #{Shellwords.escape(Dir.pwd)} && git status --porcelain 2>/dev/null`.strip.split("\n").reject(&:empty?)
          recent = `cd #{Shellwords.escape(Dir.pwd)} && git log --oneline -5 2>/dev/null`.strip.split("\n").reject(&:empty?)
          { branch: branch, status: status, recent_commits: recent }
        rescue => e
          { error: "git unavailable: #{e.message}" }
        end
      end

      def mcp_tools_list
        return { tools: [], count: 0 } unless defined?(Tina4::McpServer)
        server = Tina4._default_mcp_server
        list = server.tools.values.map do |t|
          { name: t["name"], description: t["description"], schema: t["inputSchema"] }
        end
        { tools: list, count: list.size }
      end

      def mcp_tool_call(body)
        tool_name = body["name"].to_s
        args      = body["arguments"] || {}
        return { error: "tool name required" } if tool_name.empty?
        return { error: "MCP not loaded" } unless defined?(Tina4::McpServer)
        server = Tina4._default_mcp_server
        payload = JSON.generate({
          "jsonrpc" => "2.0",
          "id"      => 1,
          "method"  => "tools/call",
          "params"  => { "name" => tool_name, "arguments" => args }
        })
        raw = server.handle_message(payload)
        return {} if raw.nil? || raw.empty?
        JSON.parse(raw)
      end

      def scaffold_templates
        # Expose built-in scaffold targets for the dev-admin UI.
        { templates: [
          { id: "route",      label: "Route file",           target: "src/routes" },
          { id: "model",      label: "ORM model",            target: "src/orm" },
          { id: "migration",  label: "SQL migration",        target: "migrations" },
          { id: "middleware", label: "Middleware class",     target: "src/app" }
        ] }
      end

      def scaffold_run(body)
        kind = body["kind"].to_s
        name = body["name"].to_s.strip
        return { ok: false, error: "kind + name required" } if kind.empty? || name.empty?
        project = Dir.pwd
        case kind
        when "route"
          target = File.join(project, "src", "routes", "#{name}.rb")
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, "# #{name} routes\nTina4::Router.get(\"/api/#{name}\") do |req, res|\n  res.call({ hello: \"#{name}\" })\nend\n") unless File.exist?(target)
          { ok: true, created: target.sub("#{project}/", "") }
        when "model"
          target = File.join(project, "src", "orm", "#{name}.rb")
          FileUtils.mkdir_p(File.dirname(target))
          cls = name.to_s.split(/[_-]/).map(&:capitalize).join
          File.write(target, "class #{cls} < Tina4::ORM\n  integer_field :id, primary_key: true, auto_increment: true\n  string_field :name\nend\n") unless File.exist?(target)
          { ok: true, created: target.sub("#{project}/", "") }
        when "migration"
          ts = Time.now.strftime("%Y%m%d%H%M%S")
          target = File.join(project, "migrations", "#{ts}_#{name}.sql")
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, "-- migration: #{name}\n")
          { ok: true, created: target.sub("#{project}/", "") }
        when "middleware"
          target = File.join(project, "src", "app", "#{name}.rb")
          FileUtils.mkdir_p(File.dirname(target))
          cls = name.to_s.split(/[_-]/).map(&:capitalize).join
          File.write(target, "class #{cls}\n  def self.before_check(req, res); [req, res]; end\nend\n") unless File.exist?(target)
          { ok: true, created: target.sub("#{project}/", "") }
        else
          { ok: false, error: "unknown kind: #{kind}" }
        end
      end

      # ── Live Docs (Live API RAG) ─────────────────────────────────

      def docs_search_payload(env)
        q = (query_param(env, "q") || "").to_s
        k = (query_param(env, "k") || "5").to_i
        source = (query_param(env, "source") || "all").to_s
        include_private = %w[1 true yes].include?((query_param(env, "include_private") || "").to_s.downcase)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        results = Tina4::Docs.cached(Dir.pwd).search(
          q, k: k, source: source, include_private: include_private
        )
        took_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0).round(2)
        { ok: true, query: q, results: results, took_ms: took_ms }
      end

      def docs_class_payload(name)
        spec = Tina4::Docs.cached(Dir.pwd).class_spec(name.to_s)
        return { ok: false, error: "class not found: #{name}" } if spec.nil?
        { ok: true, class: spec }
      end

      def docs_method_payload(class_fqn, name)
        spec = Tina4::Docs.cached(Dir.pwd).method_spec(class_fqn.to_s, name.to_s)
        return { ok: false, error: "method not found: #{class_fqn}##{name}" } if spec.nil?
        { ok: true, method: spec }
      end

      def docs_index_payload(source)
        idx = Tina4::Docs.cached(Dir.pwd).index
        idx = idx.select { |e| e[:source] == source } if source && %w[framework user vendor].include?(source.to_s)
        { ok: true, count: idx.size, entries: idx }
      end

      def docs_well_known_payload
        {
          ok: true,
          service: "tina4-live-docs",
          version: Tina4::VERSION,
          framework: "tina4-ruby",
          endpoints: {
            search: "/__dev/api/docs/search?q=<query>&k=<int>&source=<framework|user|all>&include_private=<bool>",
            class:  "/__dev/api/docs/class?name=<fqn>",
            method: "/__dev/api/docs/method?class=<fqn>&name=<method>",
            index:  "/__dev/api/docs/index?source=<framework|user|all>",
          },
          mcp: { url: "/__dev/api/mcp", tools: %w[api_search api_class api_method] },
          spec: "https://tina4.com — Live API RAG plan/v3/22-LIVE-API-RAG.md",
        }
      end
    end
  end
end
