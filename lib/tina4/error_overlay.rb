# frozen_string_literal: true

# Tina4 Debug — Rich error overlay for development mode.
#
# Renders a professional, syntax-highlighted HTML error page when an unhandled
# exception occurs in a route handler.
#
#   begin
#     handler.call(request, response)
#   rescue => e
#     Tina4::ErrorOverlay.render(e, request: env)
#   end
#
# Only activate when TINA4_DEBUG is true.
# In production, call Tina4::ErrorOverlay.render_production instead.

module Tina4
  module ErrorOverlay
    # ── Colour palette (Catppuccin Mocha) ──────────────────────────────
    BG            = "#1e1e2e"
    SURFACE       = "#313244"
    OVERLAY_COLOR = "#45475a"
    TEXT_COLOR    = "#cdd6f4"
    SUBTEXT       = "#a6adc8"
    RED           = "#f38ba8"
    YELLOW        = "#f9e2af"
    BLUE          = "#89b4fa"
    GREEN         = "#a6e3a1"
    LAVENDER      = "#b4befe"
    PEACH         = "#fab387"
    ERROR_LINE_BG = "rgba(243,139,168,0.15)"

    CONTEXT_LINES = 7

    class << self
      # Render a rich HTML error overlay.
      #
      # @param exception [Exception] the caught exception
      # @param request [Hash, nil] optional request details (Rack env or custom hash)
      # @return [String] complete HTML page
      def render(exception, request: nil)
        exc_type = exception.class.name
        exc_msg  = exception.message

        # ── Stack trace ──
        frames_html = +""
        backtrace = exception.backtrace || []
        backtrace.each do |line|
          file, lineno, method = parse_backtrace_line(line)
          frames_html << format_frame(file, lineno, method)
        end

        # ── Request info ──
        request_pairs = []
        if request.is_a?(Hash)
          request.each do |k, v|
            key = k.to_s
            if v.is_a?(Hash)
              v.each { |hk, hv| request_pairs << ["#{key}.#{hk}", hv.to_s] }
            elsif key.start_with?("HTTP_") || %w[REQUEST_METHOD REQUEST_URI SERVER_PROTOCOL
              REMOTE_ADDR SERVER_PORT QUERY_STRING CONTENT_TYPE CONTENT_LENGTH
              method url path].include?(key)
              request_pairs << [key, v.to_s]
            end
          end
        end
        request_section = request_pairs.empty? ? "" : collapsible("Request Details", table(request_pairs))

        # ── Environment ──
        env_pairs = [
          ["Framework", "Tina4 Ruby"],
          ["Version", defined?(Tina4::VERSION) ? Tina4::VERSION : "unknown"],
          ["Ruby", RUBY_VERSION],
          ["Platform", RUBY_PLATFORM],
          ["Debug", ENV.fetch("TINA4_DEBUG", "false")],
          ["Log Level", ENV.fetch("TINA4_LOG_LEVEL", "ERROR")]
        ]
        env_section = collapsible("Environment", table(env_pairs))
        stack_section = collapsible("Stack Trace", frames_html, open_by_default: true)

        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>Tina4 Error — #{esc(exc_type)}</title>
          <style>
          *{margin:0;padding:0;box-sizing:border-box;}
          body{background:#{BG};color:#{TEXT_COLOR};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;padding:24px;line-height:1.5;}
          </style>
          </head>
          <body>
          <div style="max-width:960px;margin:0 auto;">
            <div style="margin-bottom:24px;">
              <div style="display:flex;align-items:center;gap:12px;margin-bottom:12px;">
                <span style="background:#{RED};color:#{BG};padding:4px 12px;border-radius:4px;font-weight:700;font-size:13px;text-transform:uppercase;">Error</span>
                <span style="color:#{SUBTEXT};font-size:14px;">Tina4 Debug Overlay</span>
              </div>
              <h1 style="color:#{RED};font-size:28px;font-weight:700;margin-bottom:8px;">#{esc(exc_type)}</h1>
              <p style="color:#{TEXT_COLOR};font-size:18px;font-family:'SF Mono','Fira Code','Consolas',monospace;background:#{SURFACE};padding:12px 16px;border-radius:6px;border-left:4px solid #{RED};">#{esc(exc_msg)}</p>
            </div>
            #{stack_section}
            #{request_section}
            #{env_section}
            <div style="margin-top:32px;padding-top:16px;border-top:1px solid #{OVERLAY_COLOR};color:#{SUBTEXT};font-size:12px;">
              Tina4 Debug Overlay &mdash; This page is only shown in debug mode. Set TINA4_DEBUG=false in production.
            </div>
          </div>
          </body>
          </html>
        HTML
      end

      # Render a safe, generic error page for production.
      def render_production(status_code: 500, message: "Internal Server Error", path: "")
        # Determine color based on status code
        code_color = case status_code
                     when 403 then "#f59e0b"
                     when 404 then "#3b82f6"
                     else "#ef4444"
                     end

        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{status_code} — #{esc(message)}</title>
          <style>
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body { font-family: system-ui, -apple-system, sans-serif; background: #0f172a; color: #e2e8f0; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
          .error-card { background: #1e293b; border: 1px solid #334155; border-radius: 1rem; padding: 3rem; text-align: center; max-width: 520px; width: 90%; }
          .error-code { font-size: 8rem; font-weight: 900; color: #{code_color}; opacity: 0.6; line-height: 1; margin-bottom: 0.5rem; }
          .error-title { font-size: 1.5rem; font-weight: 700; margin-bottom: 0.75rem; }
          .error-msg { color: #94a3b8; font-size: 1rem; margin-bottom: 1.5rem; line-height: 1.5; }
          .error-path { font-family: 'SF Mono', monospace; background: #0f172a; color: #{code_color}; padding: 0.5rem 1rem; border-radius: 0.5rem; font-size: 0.85rem; word-break: break-all; margin-bottom: 1.5rem; display: inline-block; }
          .error-home { display: inline-block; padding: 0.6rem 2rem; background: #3b82f6; color: #fff; text-decoration: none; border-radius: 0.5rem; font-size: 0.9rem; font-weight: 600; }
          .error-home:hover { opacity: 0.9; }
          .logo { font-size: 1.5rem; margin-bottom: 1rem; opacity: 0.5; }
          </style>
          </head>
          <body>
          <div class="error-card">
              <div class="logo">T4</div>
              <div class="error-code">#{status_code}</div>
              <div class="error-title">#{esc(message)}</div>
              <div class="error-msg">Something went wrong while processing your request.</div>
              #{path.to_s.empty? ? '' : "<div class=\"error-path\">#{esc(path)}</div><br>"}
              <a href="/" class="error-home">Go Home</a>
          </div>
          </body>
          </html>
        HTML
      end

      # Return true if TINA4_DEBUG is enabled.
      def debug_mode?
        Tina4::Env.truthy?(ENV.fetch("TINA4_DEBUG", ""))
      end

      private

      def esc(text)
        text.to_s
            .gsub("&", "&amp;")
            .gsub("<", "&lt;")
            .gsub(">", "&gt;")
            .gsub('"', "&quot;")
            .gsub("'", "&#39;")
      end

      def parse_backtrace_line(line)
        if line =~ /\A(.+):(\d+):in [`'](.+)'\z/
          [$1, $2.to_i, $3]
        elsif line =~ /\A(.+):(\d+)\z/
          [$1, $2.to_i, "{main}"]
        else
          [line, 0, "{unknown}"]
        end
      end

      def read_source_lines(filename, lineno)
        return [] unless filename && lineno.positive? && File.file?(filename) && File.readable?(filename)

        all_lines = File.readlines(filename, chomp: true)
        start_idx = [0, lineno - CONTEXT_LINES - 1].max
        end_idx   = [all_lines.length, lineno + CONTEXT_LINES].min
        (start_idx...end_idx).map do |i|
          num = i + 1
          [num, all_lines[i] || "", num == lineno]
        end
      rescue StandardError
        []
      end

      def format_source_block(filename, lineno)
        lines = read_source_lines(filename, lineno)
        return "" if lines.empty?

        rows = lines.map do |num, text, is_error|
          bg = is_error ? "background:#{ERROR_LINE_BG};" : ""
          marker = is_error ? "&#x25b6;" : " "
          "<div style=\"#{bg}display:flex;padding:1px 0;\">" \
            "<span style=\"color:#{YELLOW};min-width:3.5em;text-align:right;padding-right:1em;user-select:none;\">#{num}</span>" \
            "<span style=\"color:#{RED};width:1.2em;user-select:none;\">#{marker}</span>" \
            "<span style=\"color:#{TEXT_COLOR};white-space:pre-wrap;tab-size:4;\">#{esc(text)}</span>" \
            "</div>"
        end.join("\n")

        "<div style=\"background:#{SURFACE};border-radius:6px;padding:12px;overflow-x:auto;" \
          "font-family:'SF Mono','Fira Code','Consolas',monospace;font-size:13px;line-height:1.6;\">" \
          "#{rows}</div>"
      end

      def format_frame(filename, lineno, func_name)
        source = (filename && lineno.positive?) ? format_source_block(filename, lineno) : ""
        "<div style=\"margin-bottom:16px;\">" \
          "<div style=\"margin-bottom:4px;\">" \
          "<span style=\"color:#{BLUE};\">#{esc(filename.to_s)}</span>" \
          "<span style=\"color:#{SUBTEXT};\"> : </span>" \
          "<span style=\"color:#{YELLOW};\">#{lineno}</span>" \
          "<span style=\"color:#{SUBTEXT};\"> in </span>" \
          "<span style=\"color:#{GREEN};\">#{esc(func_name.to_s)}</span>" \
          "</div>" \
          "#{source}" \
          "</div>"
      end

      def collapsible(title, content, open_by_default: false)
        open_attr = open_by_default ? " open" : ""
        "<details style=\"margin-top:16px;\"#{open_attr}>" \
          "<summary style=\"cursor:pointer;color:#{LAVENDER};font-weight:600;font-size:15px;" \
          "padding:8px 0;user-select:none;\">#{esc(title)}</summary>" \
          "<div style=\"padding:8px 0;\">#{content}</div>" \
          "</details>"
      end

      def table(pairs)
        return "<span style=\"color:#{SUBTEXT};\">None</span>" if pairs.empty?

        rows = pairs.map do |key, val|
          "<tr>" \
            "<td style=\"color:#{PEACH};padding:4px 16px 4px 0;vertical-align:top;white-space:nowrap;\">#{esc(key)}</td>" \
            "<td style=\"color:#{TEXT_COLOR};padding:4px 0;word-break:break-all;\">#{esc(val)}</td>" \
            "</tr>"
        end.join
        "<table style=\"border-collapse:collapse;width:100%;\">#{rows}</table>"
      end
    end
  end
end
