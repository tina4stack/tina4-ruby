# frozen_string_literal: true

require "json"

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

      def enabled?
        Tina4::Env.truthy?(ENV["TINA4_DEBUG"])
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
        when ["GET", "/__dev/api/queue"]
          json_response({ jobs: [], stats: { pending: 0, completed: 0, failed: 0, reserved: 0 } })
        when ["GET", "/__dev/api/mailbox"]
          messages = mailbox.inbox
          json_response({ messages: messages, count: messages.size, unread: mailbox.unread_count })
        when ["GET", "/__dev/api/broken"]
          json_response({ errors: [], health: { total: 0, unresolved: 0, resolved: 0, healthy: true } })
        when ["POST", "/__dev/api/broken/resolve"]
          body = read_json_body(env)
          # TODO: resolve tracked error by id from body["id"]
          json_response({ resolved: true })
        when ["POST", "/__dev/api/broken/clear"]
          # TODO: clear resolved errors
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

      def serve_dashboard
        [200, { "content-type" => "text/html; charset=utf-8" }, [render_dashboard]]
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
        {
          framework: "tina4-ruby",
          version: Tina4::VERSION,
          ruby_version: RUBY_VERSION,
          platform: RUBY_PLATFORM,
          debug: ENV["TINA4_DEBUG"] || "false",
          log_level: ENV["TINA4_LOG_LEVEL"] || "ERROR",
          uptime: (Time.now - (defined?(@boot_time) && @boot_time ? @boot_time : (@boot_time = Time.now))).round(1),
          route_count: Tina4::Router.routes.size,
          request_stats: request_inspector.stats,
          message_counts: message_log.count
        }
      end

      def routes_payload
        internal_prefixes = ["/__dev", "/health", "/swagger"]
        routes = Tina4::Router.routes
          .reject { |route| internal_prefixes.any? { |prefix| route.path.start_with?(prefix) } }
          .map do |route|
          {
            method: route.method,
            pattern: route.path,
            middleware: route.respond_to?(:middleware_count) ? route.middleware_count : 0,
            cache: route.respond_to?(:cached?) ? route.cached? : false,
            secure: !route.auth_handler.nil?
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
          env: ENV["TINA4_ENV"] || ENV["RACK_ENV"] || ENV["RUBY_ENV"] || "development"
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

        first_word = sql.split(/[\s\t\n\r]+/, 2).first.to_s.upcase
        unless %w[SELECT PRAGMA EXPLAIN SHOW DESCRIBE].include?(first_word)
          return { error: "Only SELECT queries are allowed in the dev dashboard" }
        end

        db = Tina4.database
        return { error: "No database configured" } unless db

        begin
          result = db.fetch(sql)
          rows = result.respond_to?(:to_a) ? result.to_a : (result.is_a?(Array) ? result : [])
          columns = rows.first.is_a?(Hash) ? rows.first.keys.map(&:to_s) : []
          { columns: columns, rows: rows, count: rows.size }
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

      def render_dashboard
        <<~'HTML'
          <!DOCTYPE html>
          <html lang="en">
          <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Tina4 Dev Admin</title>
          <style>
          :root {
              --bg: #0f172a; --surface: #1e293b; --border: #334155;
              --text: #e2e8f0; --muted: #94a3b8; --primary: #c62828;
              --success: #22c55e; --danger: #ef4444; --warn: #f59e0b;
              --info: #06b6d4; --radius: 0.5rem;
              --mono: 'SF Mono', 'Fira Code', 'Consolas', monospace;
              --font: system-ui, -apple-system, sans-serif;
          }
          * { box-sizing: border-box; margin: 0; padding: 0; }

          body { font-family: var(--font); background: var(--bg); color: var(--text); font-size: 0.875rem; }
          .dev-header {
              background: var(--surface); border-bottom: 1px solid var(--border);
              padding: 0.75rem 1.5rem; display: flex; align-items: center; gap: 1rem;
          }
          .dev-header h1 { font-size: 1rem; font-weight: 600; }
          .dev-header .badge {
              background: var(--primary); color: #fff; padding: 0.15rem 0.5rem;
              border-radius: 1rem; font-size: 0.7rem; font-weight: 600;
          }
          .dev-tabs {
              display: flex; gap: 0; background: var(--surface);
              border-bottom: 1px solid var(--border); overflow-x: auto;
          }
          .dev-tab {
              padding: 0.6rem 1rem; cursor: pointer; font-size: 0.8rem;
              border-bottom: 2px solid transparent; color: var(--muted);
              transition: all 0.15s; background: none; border-top: none;
              border-left: none; border-right: none; white-space: nowrap;
          }
          .dev-tab:hover { color: var(--text); }
          .dev-tab.active { color: var(--primary); border-bottom-color: var(--primary); }
          .dev-tab .count {
              background: var(--border); color: var(--muted); padding: 0.1rem 0.4rem;
              border-radius: 0.75rem; font-size: 0.65rem; margin-left: 0.25rem;
          }
          .dev-content { padding: 1rem; max-width: 1400px; }
          .dev-panel {
              background: var(--surface); border: 1px solid var(--border);
              border-radius: var(--radius); overflow: hidden;
          }
          .dev-panel-header {
              padding: 0.75rem 1rem; border-bottom: 1px solid var(--border);
              display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 0.5rem;
          }
          .dev-panel-header h2 { font-size: 0.9rem; font-weight: 600; }
          table { width: 100%; border-collapse: collapse; font-size: 0.8rem; }
          th { text-align: left; padding: 0.5rem 0.75rem; color: var(--muted); font-weight: 500; border-bottom: 1px solid var(--border); }
          td { padding: 0.4rem 0.75rem; border-bottom: 1px solid var(--border); }
          tr:hover { background: rgba(198, 40, 40, 0.05); }
          .method { font-family: var(--mono); font-size: 0.7rem; font-weight: 700; }
          .method-get { color: var(--success); }
          .method-post { color: var(--primary); }
          .method-put { color: var(--warn); }
          .method-delete { color: var(--danger); }
          .path { font-family: var(--mono); font-size: 0.75rem; }
          .badge-pill {
              display: inline-block; padding: 0.1rem 0.5rem; border-radius: 1rem;
              font-size: 0.65rem; font-weight: 600; text-transform: uppercase;
          }
          .bg-pending { background: rgba(245,158,11,0.15); color: var(--warn); }
          .bg-completed, .bg-success { background: rgba(34,197,94,0.15); color: var(--success); }
          .bg-failed, .bg-danger { background: rgba(239,68,68,0.15); color: var(--danger); }
          .bg-reserved, .bg-primary { background: rgba(198,40,40,0.15); color: var(--primary); }
          .bg-info { background: rgba(6,182,212,0.15); color: var(--info); }
          .btn {
              padding: 0.3rem 0.65rem; border: 1px solid var(--border); border-radius: var(--radius);
              background: var(--surface); color: var(--text); cursor: pointer; font-size: 0.75rem;
              transition: all 0.15s;
          }
          .btn:hover { border-color: var(--primary); color: var(--primary); }
          .btn-primary { background: var(--primary); color: #fff; border-color: var(--primary); }
          .btn-primary:hover { background: #d32f2f; }
          .btn-danger { border-color: var(--danger); color: var(--danger); }
          .btn-danger:hover { background: rgba(239,68,68,0.1); }
          .btn-success { border-color: var(--success); color: var(--success); }
          .btn-sm { padding: 0.2rem 0.5rem; font-size: 0.7rem; }
          .empty { padding: 2rem; text-align: center; color: var(--muted); }
          .input {
              background: var(--bg); color: var(--text); border: 1px solid var(--border);
              border-radius: var(--radius); padding: 0.35rem 0.5rem; font-size: 0.8rem;
              font-family: var(--font);
          }
          .input:focus { outline: none; border-color: var(--primary); }
          .input-mono { font-family: var(--mono); }
          select.input { padding: 0.3rem; }
          textarea.input { resize: vertical; font-family: var(--mono); }
          .flex { display: flex; }
          .gap-sm { gap: 0.5rem; }
          .gap-md { gap: 1rem; }
          .items-center { align-items: center; }
          .justify-between { justify-content: space-between; }
          .flex-1 { flex: 1; }
          .p-sm { padding: 0.5rem; }
          .p-md { padding: 1rem; }
          .mb-sm { margin-bottom: 0.5rem; }
          .text-sm { font-size: 0.75rem; }
          .text-muted { color: var(--muted); }
          .text-mono { font-family: var(--mono); }
          .mail-item { padding: 0.6rem 0.75rem; border-bottom: 1px solid var(--border); cursor: pointer; }
          .mail-item:hover { background: rgba(198,40,40,0.05); }
          .mail-item.unread { border-left: 3px solid var(--primary); }
          .msg-entry { padding: 0.4rem 0.75rem; border-bottom: 1px solid var(--border); font-size: 0.75rem; }
          .msg-entry .cat {
              font-family: var(--mono); font-size: 0.65rem; padding: 0.1rem 0.35rem;
              border-radius: 0.25rem; background: rgba(198,40,40,0.15); color: var(--primary);
          }
          .msg-entry .time { color: var(--muted); font-size: 0.7rem; font-family: var(--mono); }
          .level-error { color: var(--danger); }
          .level-warn { color: var(--warn); }
          .toolbar { display: flex; gap: 0.5rem; padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--border); flex-wrap: wrap; align-items: center; }
          .hidden { display: none; }
          /* Chat panel */
          .chat-container { display: flex; flex-direction: column; height: 500px; }
          .chat-messages { flex: 1; overflow-y: auto; padding: 0.75rem; }
          .chat-msg { margin-bottom: 0.75rem; padding: 0.5rem 0.75rem; border-radius: var(--radius); font-size: 0.8rem; max-width: 85%; }
          .chat-user { background: var(--primary); color: #fff; margin-left: auto; }
          .chat-bot { background: var(--bg); border: 1px solid var(--border); }
          .chat-input-row { display: flex; gap: 0.5rem; padding: 0.75rem; border-top: 1px solid var(--border); }
          .chat-input-row input { flex: 1; }
          /* System cards */
          .sys-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 0.75rem; padding: 1rem; }
          .sys-card { background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius); padding: 0.75rem; }
          .sys-card .label { font-size: 0.7rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
          .sys-card .value { font-size: 1.25rem; font-weight: 600; margin-top: 0.25rem; }
          /* Request table */
          .status-ok { color: var(--success); }
          .status-err { color: var(--danger); }
          .status-warn { color: var(--warn); }
          /* Filter buttons */
          .filter-btn { cursor: pointer; }
          .filter-btn.active { border-color: var(--primary); color: var(--primary); }
          code, .mono { font-family: var(--mono); font-size: 0.82rem; }
          </style>
          </head>
          <body>

          <div class="dev-header">
              <img src="https://tina4.com/logo.svg" style="width:1.5rem;height:1.5rem;cursor:pointer;opacity:0.7;transition:opacity 0.15s" title="Back to app" onclick="exitDevAdmin()" onmouseover="this.style.opacity='1'" onmouseout="this.style.opacity='0.7'" alt="Tina4">
              <h1>Tina4 Dev Admin</h1>
              <span class="badge">DEV</span>
              <span style="margin-left:auto; font-size:0.75rem; color:var(--muted)" id="timestamp"></span>
          </div>

          <div class="dev-tabs">
              <button class="dev-tab active" onclick="showTab('routes', event)">Routes <span class="count" id="routes-count">0</span></button>
              <button class="dev-tab" onclick="showTab('queue', event)">Queue <span class="count" id="queue-count">0</span></button>
              <button class="dev-tab" onclick="showTab('mailbox', event)">Mailbox <span class="count" id="mailbox-count">0</span></button>
              <button class="dev-tab" onclick="showTab('messages', event)">Messages <span class="count" id="messages-count">0</span></button>
              <button class="dev-tab" onclick="showTab('database', event)">Database <span class="count" id="db-count">0</span></button>
              <button class="dev-tab" onclick="showTab('requests', event)">Requests <span class="count" id="req-count">0</span></button>
              <button class="dev-tab" onclick="showTab('errors', event)">Errors <span class="count" id="err-count">0</span></button>
              <button class="dev-tab" onclick="showTab('websockets', event)">WS <span class="count" id="ws-count">0</span></button>
              <button class="dev-tab" onclick="showTab('system', event)">System</button>
              <button class="dev-tab" onclick="showTab('tools', event)">Tools</button>
              <button class="dev-tab" onclick="showTab('connections', event)">Connections</button>
              <button class="dev-tab" onclick="showTab('chat', event)">Tina4</button>
          </div>

          <div class="dev-content">

          <!-- Routes Panel -->
          <div id="panel-routes" class="dev-panel">
              <div class="dev-panel-header">
                  <h2>Registered Routes</h2>
                  <button class="btn btn-sm" onclick="loadRoutes()">Refresh</button>
              </div>
              <table>
                  <thead><tr><th>Method</th><th>Path</th><th>Auth</th><th>Handler</th></tr></thead>
                  <tbody id="routes-body"></tbody>
              </table>
          </div>

          <!-- Queue Panel -->
          <div id="panel-queue" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>Queue Jobs</h2>
                  <div class="flex gap-sm">
                      <button class="btn btn-sm" onclick="loadQueue()">Refresh</button>
                      <button class="btn btn-sm" onclick="retryQueue()">Retry Failed</button>
                      <button class="btn btn-sm btn-danger" onclick="purgeQueue()">Purge Done</button>
                  </div>
              </div>
              <div class="toolbar">
                  <button class="btn btn-sm filter-btn active" onclick="filterQueue('', event)">All</button>
                  <button class="btn btn-sm filter-btn" onclick="filterQueue('pending', event)">Pending <span id="q-pending">0</span></button>
                  <button class="btn btn-sm filter-btn" onclick="filterQueue('completed', event)">Done <span id="q-completed">0</span></button>
                  <button class="btn btn-sm filter-btn" onclick="filterQueue('failed', event)">Failed <span id="q-failed">0</span></button>
                  <button class="btn btn-sm filter-btn" onclick="filterQueue('reserved', event)">Active <span id="q-reserved">0</span></button>
              </div>
              <table>
                  <thead><tr><th>ID</th><th>Topic</th><th>Status</th><th>Attempts</th><th>Created</th><th>Data</th><th></th></tr></thead>
                  <tbody id="queue-body"></tbody>
              </table>
              <div id="queue-empty" class="empty hidden">No queue jobs</div>
          </div>

          <!-- Mailbox Panel -->
          <div id="panel-mailbox" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>Dev Mailbox</h2>
                  <div class="flex gap-sm">
                      <button class="btn btn-sm" onclick="loadMailbox()">Refresh</button>
                      <button class="btn btn-sm btn-primary" onclick="seedMailbox()">Seed 5</button>
                      <button class="btn btn-sm btn-danger" onclick="clearMailbox()">Clear</button>
                  </div>
              </div>
              <div class="toolbar">
                  <button class="btn btn-sm filter-btn active" onclick="filterMailbox('', event)">All</button>
                  <button class="btn btn-sm filter-btn" onclick="filterMailbox('inbox', event)">Inbox</button>
                  <button class="btn btn-sm filter-btn" onclick="filterMailbox('outbox', event)">Outbox</button>
              </div>
              <div id="mailbox-list"></div>
              <div id="mail-detail" class="hidden p-md"></div>
          </div>

          <!-- Messages Panel -->
          <div id="panel-messages" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>Message Log</h2>
                  <div class="flex gap-sm items-center">
                      <input type="text" id="msg-search" class="input" placeholder="Search messages..." onkeydown="if(event.key==='Enter')searchMessages()">
                      <button class="btn btn-sm" onclick="searchMessages()">Search</button>
                      <button class="btn btn-sm" onclick="loadMessages()">All</button>
                      <button class="btn btn-sm btn-danger" onclick="clearMessages()">Clear</button>
                  </div>
              </div>
              <div id="messages-list"></div>
              <div id="messages-empty" class="empty">No messages logged</div>
          </div>

          <!-- Database Panel -->
          <div id="panel-database" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>Database</h2>
                  <button class="btn btn-sm" onclick="loadTables()">Refresh</button>
              </div>
              <div class="flex gap-md p-md">
                  <div class="flex-1">
                      <div class="flex gap-sm items-center mb-sm">
                          <select id="query-type" class="input">
                              <option value="sql">SQL</option>
                          </select>
                          <button class="btn btn-sm btn-primary" onclick="runQuery()">Run</button>
                          <span class="text-sm text-muted">Ctrl+Enter</span>
                      </div>
                      <textarea id="query-input" rows="4" placeholder="SELECT * FROM users LIMIT 20" class="input input-mono" style="width:100%"></textarea>
                      <div id="query-error" class="hidden" style="color:var(--danger);font-size:0.75rem;margin-top:0.25rem"></div>
                  </div>
                  <div style="width:180px">
                      <div class="text-sm text-muted" style="font-weight:600;margin-bottom:0.5rem">Tables</div>
                      <div id="table-list" class="text-sm"></div>
                      <div style="margin-top:0.75rem;border-top:1px solid var(--border);padding-top:0.75rem">
                          <div class="text-sm text-muted" style="font-weight:600;margin-bottom:0.5rem">Seed Data</div>
                          <select id="seed-table" class="input" style="width:100%;margin-bottom:0.25rem"><option value="">Pick table...</option></select>
                          <div class="flex gap-sm items-center">
                              <input type="number" id="seed-count" class="input" value="10" min="1" max="1000" style="width:60px">
                              <button class="btn btn-sm btn-success" onclick="seedTable()">Seed</button>
                          </div>
                      </div>
                  </div>
              </div>
              <div id="query-results" style="overflow-x:auto"></div>
          </div>

          <!-- Requests Panel -->
          <div id="panel-requests" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>Request Inspector</h2>
                  <div class="flex gap-sm">
                      <button class="btn btn-sm" onclick="loadRequests()">Refresh</button>
                      <button class="btn btn-sm btn-danger" onclick="clearRequests()">Clear</button>
                  </div>
              </div>
              <div id="req-stats" class="toolbar text-sm text-muted"></div>
              <table>
                  <thead><tr><th>Time</th><th>Method</th><th>Path</th><th>Status</th><th>Duration</th><th>Size</th></tr></thead>
                  <tbody id="req-body"></tbody>
              </table>
              <div id="req-empty" class="empty hidden">No requests captured</div>
          </div>

          <!-- Errors Panel -->
          <div id="panel-errors" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>Error Tracker</h2>
                  <div class="flex gap-sm">
                      <button class="btn btn-sm" onclick="loadErrors()">Refresh</button>
                      <button class="btn btn-sm btn-danger" onclick="clearResolvedErrors()">Clear Resolved</button>
                  </div>
              </div>
              <div id="errors-list"></div>
              <div id="errors-empty" class="empty">No errors tracked</div>
          </div>

          <!-- WebSocket Panel -->
          <div id="panel-websockets" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>WebSocket Connections</h2>
                  <button class="btn btn-sm" onclick="loadWebSockets()">Refresh</button>
              </div>
              <table>
                  <thead><tr><th>ID</th><th>Path</th><th>IP</th><th>Connected</th><th>Status</th><th></th></tr></thead>
                  <tbody id="ws-body"></tbody>
              </table>
              <div id="ws-empty" class="empty">No active connections</div>
          </div>

          <!-- System Panel -->
          <div id="panel-system" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>System Overview</h2>
                  <button class="btn btn-sm" onclick="loadSystem()">Refresh</button>
              </div>
              <div id="sys-cards" class="sys-grid"></div>
              <div id="sys-extensions" class="hidden"></div>
          </div>

          <!-- Tools Panel -->
          <div id="panel-tools" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>Developer Tools</h2>
              </div>
              <div class="sys-grid">
                  <div class="sys-card" style="cursor:pointer" onclick="runTool('test')">
                      <div class="label">Run Tests</div>
                      <div style="font-size:0.8rem;margin-top:0.25rem">Execute the RSpec test suite</div>
                  </div>
                  <div class="sys-card" style="cursor:pointer" onclick="runTool('routes')">
                      <div class="label">List Routes</div>
                      <div style="font-size:0.8rem;margin-top:0.25rem">Show all registered routes with auth status</div>
                  </div>
                  <div class="sys-card" style="cursor:pointer" onclick="runTool('migrate')">
                      <div class="label">Run Migrations</div>
                      <div style="font-size:0.8rem;margin-top:0.25rem">Apply pending database migrations</div>
                  </div>
                  <div class="sys-card" style="cursor:pointer" onclick="runTool('seed')">
                      <div class="label">Run Seeders</div>
                      <div style="font-size:0.8rem;margin-top:0.25rem">Execute seed scripts</div>
                  </div>
              </div>
              <div id="tool-output" class="hidden" style="margin:1rem">
                  <div class="dev-panel-header">
                      <h2 id="tool-title">Output</h2>
                      <button class="btn btn-sm" onclick="document.getElementById('tool-output').classList.add('hidden')">Close</button>
                  </div>
                  <pre id="tool-result" style="padding:1rem;background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);font-size:0.75rem;font-family:var(--mono);max-height:400px;overflow:auto;white-space:pre-wrap"></pre>
              </div>
          </div>

          <!-- Connections Panel -->
          <div id="panel-connections" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>Connection Builder</h2>
              </div>
              <div class="p-md">
                  <div class="flex gap-md" style="flex-wrap:wrap">
                      <div style="flex:1;min-width:300px">
                          <div class="mb-sm">
                              <label class="text-sm text-muted" style="display:block;margin-bottom:0.25rem">Driver</label>
                              <select id="conn-driver" class="input" style="width:100%" onchange="connDriverChanged()">
                                  <option value="sqlite">SQLite</option>
                                  <option value="postgresql">PostgreSQL</option>
                                  <option value="mysql">MySQL</option>
                                  <option value="mssql">MSSQL</option>
                                  <option value="firebird">Firebird</option>
                              </select>
                          </div>
                          <div class="mb-sm conn-server-field">
                              <label class="text-sm text-muted" style="display:block;margin-bottom:0.25rem">Host</label>
                              <input type="text" id="conn-host" class="input" style="width:100%" value="localhost" placeholder="localhost" oninput="updateConnectionUrl()">
                          </div>
                          <div class="mb-sm conn-server-field">
                              <label class="text-sm text-muted" style="display:block;margin-bottom:0.25rem">Port</label>
                              <input type="number" id="conn-port" class="input" style="width:100%" placeholder="5432" oninput="updateConnectionUrl()">
                          </div>
                          <div class="mb-sm">
                              <label class="text-sm text-muted" style="display:block;margin-bottom:0.25rem">Database</label>
                              <input type="text" id="conn-database" class="input" style="width:100%" placeholder="mydb" oninput="updateConnectionUrl()">
                          </div>
                          <div class="mb-sm conn-server-field">
                              <label class="text-sm text-muted" style="display:block;margin-bottom:0.25rem">Username</label>
                              <input type="text" id="conn-username" class="input" style="width:100%" placeholder="username">
                          </div>
                          <div class="mb-sm conn-server-field">
                              <label class="text-sm text-muted" style="display:block;margin-bottom:0.25rem">Password</label>
                              <input type="password" id="conn-password" class="input" style="width:100%" placeholder="password">
                          </div>
                          <div class="mb-sm">
                              <label class="text-sm text-muted" style="display:block;margin-bottom:0.25rem">Connection URL</label>
                              <input type="text" id="conn-url" class="input input-mono" style="width:100%" readonly>
                          </div>
                          <div class="flex gap-sm">
                              <button class="btn btn-primary" onclick="testConnection()">Test Connection</button>
                              <button class="btn btn-success" onclick="saveConnection()">Save to .env</button>
                          </div>
                      </div>
                      <div style="width:300px">
                          <div class="dev-panel" style="margin-bottom:1rem">
                              <div class="dev-panel-header"><h2>Test Result</h2></div>
                              <div id="conn-test-result" class="p-md text-sm text-muted">No test run yet</div>
                          </div>
                          <div class="dev-panel">
                              <div class="dev-panel-header"><h2>Current .env Values</h2></div>
                              <div id="conn-env-values" class="p-md text-sm text-muted">Loading...</div>
                          </div>
                      </div>
                  </div>
              </div>
          </div>

          <script>
          function connDriverChanged() {
              var driver = document.getElementById('conn-driver').value;
              var ports = {postgresql: 5432, mysql: 3306, mssql: 1433, firebird: 3050};
              var isSqlite = (driver === 'sqlite');
              document.getElementById('conn-port').value = ports[driver] || '';
              var fields = document.querySelectorAll('.conn-server-field');
              for (var i = 0; i < fields.length; i++) {
                  fields[i].style.display = isSqlite ? 'none' : '';
              }
              updateConnectionUrl();
          }
          function updateConnectionUrl() {
              var driver = document.getElementById('conn-driver').value;
              var host = document.getElementById('conn-host').value || 'localhost';
              var port = document.getElementById('conn-port').value;
              var database = document.getElementById('conn-database').value;
              if (driver === 'sqlite') {
                  document.getElementById('conn-url').value = 'sqlite:///' + database;
              } else {
                  document.getElementById('conn-url').value = driver + '://' + host + ':' + port + '/' + database;
              }
          }
          function testConnection() {
              var url = document.getElementById('conn-url').value;
              var username = document.getElementById('conn-username').value;
              var password = document.getElementById('conn-password').value;
              var el = document.getElementById('conn-test-result');
              el.innerHTML = '<span class="text-muted">Testing...</span>';
              fetch('/__dev/api/connections/test', {
                  method: 'POST',
                  headers: {'Content-Type': 'application/json'},
                  body: JSON.stringify({url: url, username: username, password: password})
              }).then(function(r){return r.json()}).then(function(data) {
                  if (data.success) {
                      el.innerHTML = '<div style="color:var(--success);font-weight:600;margin-bottom:0.5rem">&#10004; Connected</div>' +
                          '<div class="text-sm">Version: ' + (data.version || 'N/A') + '</div>' +
                          '<div class="text-sm">Tables: ' + (data.tables !== undefined ? data.tables : 'N/A') + '</div>';
                  } else {
                      el.innerHTML = '<div style="color:var(--danger);font-weight:600;margin-bottom:0.5rem">&#10008; Failed</div>' +
                          '<div class="text-sm" style="color:var(--danger)">' + (data.error || 'Unknown error') + '</div>';
                  }
              }).catch(function(e) {
                  el.innerHTML = '<div style="color:var(--danger)">Error: ' + e.message + '</div>';
              });
          }
          function saveConnection() {
              var url = document.getElementById('conn-url').value;
              var username = document.getElementById('conn-username').value;
              var password = document.getElementById('conn-password').value;
              if (!url) { alert('Please build a connection URL first'); return; }
              fetch('/__dev/api/connections/save', {
                  method: 'POST',
                  headers: {'Content-Type': 'application/json'},
                  body: JSON.stringify({url: url, username: username, password: password})
              }).then(function(r){return r.json()}).then(function(data) {
                  if (data.success) {
                      alert('Connection saved to .env');
                      loadConnectionEnv();
                  } else {
                      alert('Save failed: ' + (data.error || 'Unknown error'));
                  }
              }).catch(function(e) { alert('Error: ' + e.message); });
          }
          function loadConnectionEnv() {
              fetch('/__dev/api/connections').then(function(r){return r.json()}).then(function(data) {
                  var el = document.getElementById('conn-env-values');
                  el.innerHTML = '<div class="mb-sm"><span class="text-muted">DATABASE_URL:</span> <code>' + (data.url || '<em>not set</em>') + '</code></div>' +
                      '<div class="mb-sm"><span class="text-muted">DATABASE_USERNAME:</span> <code>' + (data.username || '<em>not set</em>') + '</code></div>' +
                      '<div><span class="text-muted">DATABASE_PASSWORD:</span> <code>' + (data.password || '<em>not set</em>') + '</code></div>';
              }).catch(function() {
                  document.getElementById('conn-env-values').innerHTML = '<span class="text-muted">Could not load .env values</span>';
              });
          }
          document.addEventListener('DOMContentLoaded', function() {
              var connTab = document.querySelector('[onclick*="connections"]');
              if (connTab) {
                  connTab.addEventListener('click', function() { loadConnectionEnv(); }, {once: true});
              }
          });
          </script>

          <!-- Chat Panel (Tina4) -->
          <div id="panel-chat" class="dev-panel hidden">
              <div class="dev-panel-header">
                  <h2>Tina4</h2>
                  <div class="flex gap-sm items-center">
                      <select id="ai-provider" class="input" style="width:120px">
                          <option value="anthropic">Claude</option>
                          <option value="openai">OpenAI</option>
                      </select>
                      <input type="password" id="ai-key" class="input" placeholder="Paste API key..." style="width:250px">
                      <button class="btn btn-sm btn-primary" onclick="setAiKey()">Set Key</button>
                      <span class="text-sm text-muted" id="ai-status">No key set</span>
                  </div>
              </div>
              <div class="chat-container">
                  <div class="chat-messages" id="chat-messages">
                      <div class="chat-msg chat-bot">Hi! I'm Tina4. Ask me about routes, ORM, database, queues, templates, auth, or any Tina4 feature.</div>
                  </div>
                  <div class="chat-input-row">
                      <input type="text" id="chat-input" class="input" placeholder="Ask Tina4..." onkeydown="if(event.key==='Enter')sendChat()">
                      <button class="btn btn-primary" onclick="sendChat()">Send</button>
                  </div>
              </div>
          </div>

          </div>

          <script src="/__dev/js/tina4-dev-admin.min.js"></script>
          <script>
          // Self-diagnostic — detect if the external JS failed to load
          (function() {
              if (typeof showTab !== 'function') {
                  var banner = document.createElement('div');
                  banner.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:99999;background:#ef4444;color:#fff;padding:0.75rem 1rem;font-family:system-ui;font-size:0.85rem;text-align:center';
                  banner.innerHTML = '<strong>Dev Admin Error:</strong> tina4-dev-admin.min.js failed to load. Check that /__dev/js/tina4-dev-admin.min.js is accessible.';
                  document.body.insertBefore(banner, document.body.firstChild);
              }
          })();
          </script>
          </body>
          </html>
        HTML
      end
    end
  end
end
