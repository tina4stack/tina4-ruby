# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "openssl"

module Tina4
  class AiError < StandardError; end
  class AiConfigError < AiError; end
  class AiTimeoutError < AiError; end
  class AiParseError < AiError; end

  class AiHTTPError < AiError
    attr_reader :status

    def initialize(message, status = nil)
      super(message)
      @status = status
    end
  end

  ChatResponse = Struct.new(:text, :model, :usage, :finish_reason, :raw, keyword_init: true)

  # Zero-dependency app-facing AI client. ADR-0053 defined the base contract
  # (chat / complete / embed with a normalised, provider-neutral response
  # shape); ADR-0060 extended it with typed streaming events and multimodal
  # content parts. Both live here so the AI surface is a single file.
  class Ai
    PROVIDERS = %w[local openai anthropic].freeze

    class << self
      # chat(stream: false) still returns a ChatResponse (ADR-0053).
      # chat(stream: true) returns an Enumerator of typed events (ADR-0060):
      #
      #   { type: :text_delta, text: "..." }
      #   { type: :tool_call,  id: "...", name: "...", args: {...} }
      #   { type: :done,       finish_reason: "...", usage: {...} | nil }
      #   { type: :error,      message: "...", code: "..." | nil }
      #
      # The typed events replace the ADR-0053 string-only stream shape. That
      # was a deliberately breaking change (see ADR-0060 §7) so an agent loop
      # could observe tool_calls and finish_reason without hand-rolled SSE
      # parsing per app.
      def chat(messages, model: nil, temperature: nil, max_tokens: nil,
               stream: false, timeout: nil, provider: nil)
        validate_messages(messages)
        config = resolve_config("chat", model, timeout, provider)
        body = chat_body(config, messages, temperature, max_tokens, stream)
        return stream_events(config, headers(config), body) if stream

        normalize_chat(config[:provider], request_json(config, headers(config), body))
      end

      def complete(prompt, **options)
        raise AiConfigError, "AI prompt must be a string" unless prompt.is_a?(String)

        options.delete(:stream)
        chat([{ role: "user", content: prompt }], **options, stream: false).text
      end

      def embed(text_or_texts, model: nil, timeout: nil, provider: nil)
        single = text_or_texts.is_a?(String)
        valid_batch = text_or_texts.is_a?(Array) && !text_or_texts.empty? && text_or_texts.all? { |item| item.is_a?(String) }
        raise AiConfigError, "AI embedding input must be a string or a non-empty list of strings" unless single || valid_batch

        config = resolve_config("embed", model, timeout, provider)
        raise AiConfigError, "Anthropic does not provide the embedding endpoint in this contract" if config[:provider] == "anthropic"

        raw = request_json(config, headers(config), { model: config[:model], input: text_or_texts })
        begin
          data = raw.fetch("data").sort_by { |item| item.fetch("index", 0) }
          vectors = data.map { |item| item.fetch("embedding") }
          expected = single ? 1 : text_or_texts.length
          valid = vectors.length == expected && vectors.all? do |vector|
            vector.is_a?(Array) && !vector.empty? && vector.all? { |value| value.is_a?(Numeric) }
          end
          raise KeyError unless valid
        rescue KeyError, TypeError
          raise AiParseError, "AI provider returned a malformed embedding response"
        end
        single ? vectors.first : vectors
      end

      private

      # ── validation ─────────────────────────────────────────────────────────

      def validate_messages(messages)
        unless messages.is_a?(Array) && !messages.empty?
          raise AiConfigError, "AI messages must be a non-empty list"
        end

        messages.each do |message|
          raise AiConfigError, "AI messages must be objects" unless message.is_a?(Hash)

          role = (message[:role] || message["role"]).to_s
          unless %w[system user assistant].include?(role)
            raise AiConfigError, "AI messages must contain supported roles"
          end

          content = message.key?(:content) ? message[:content] : message["content"]
          validate_content(content)
        end
      end

      def validate_content(content)
        return if content.is_a?(String)

        unless content.is_a?(Array) && !content.empty?
          raise AiConfigError, "AI message content must be a string or a non-empty list of parts"
        end

        content.each { |part| validate_content_part(part) }
      end

      def validate_content_part(part)
        raise AiConfigError, "AI content parts must be objects" unless part.is_a?(Hash)

        type = (part[:type] || part["type"]).to_s
        case type
        when "text"
          text = part.key?(:text) ? part[:text] : part["text"]
          raise AiConfigError, "AI text content part must have a string text field" unless text.is_a?(String)
        when "image"
          source = part.key?(:source) ? part[:source] : part["source"]
          raise AiConfigError, "AI image content part must have a string source field" unless source.is_a?(String)

          if source.start_with?("data:")
            # data:<media_type>;base64,<payload> — enforce the base64 marker
            raise AiConfigError, "AI image data URI must be base64-encoded" unless source.include?(";base64,")
          elsif !source.start_with?("https://")
            raise AiConfigError, "AI image source must be a data:<mime>;base64,<data> URI or an https:// URL"
          end
        else
          raise AiConfigError, "AI content part type must be 'text' or 'image'"
        end
      end

      # ── configuration ──────────────────────────────────────────────────────

      def number(name, default, minimum)
        value = Float(ENV.fetch(name, default.to_s))
        raise AiConfigError, "#{name} must be at least #{minimum}" if value < minimum

        value
      rescue ArgumentError, TypeError
        raise AiConfigError, "#{name} must be numeric"
      end

      def resolve_config(capability, model, timeout, provider)
        selected = (provider || ENV["TINA4_AI_PROVIDER"] || "local").strip.downcase
        raise AiConfigError, "TINA4_AI_PROVIDER must be local, openai, or anthropic" unless PROVIDERS.include?(selected)

        key = ENV["TINA4_AI_KEY"]
        if %w[openai anthropic].include?(selected) && (key.nil? || key.empty?)
          raise AiConfigError, "TINA4_AI_KEY is required for the #{selected} provider"
        end
        defaults = {
          "local" => ["http://localhost:11437", "llama3.2"],
          "openai" => ["https://api.openai.com/v1", "gpt-4o-mini"],
          "anthropic" => ["https://api.anthropic.com/v1", "claude-3-5-haiku-latest"]
        }
        value = capability == "embed" && ENV["TINA4_EMBED_URL"] ? ENV["TINA4_EMBED_URL"] : (ENV["TINA4_AI_URL"] || defaults[selected][0])
        total = timeout.nil? ? number("TINA4_AI_TIMEOUT", 60, 0.001) : Float(timeout)
        raise AiConfigError, "AI timeout must be greater than zero" unless total.positive?

        chosen_model = (model || ENV["TINA4_AI_MODEL"] || defaults[selected][1]).to_s.strip
        raise AiConfigError, "AI model must be a non-empty string" if chosen_model.empty?

        {
          provider: selected,
          url: endpoint(value, capability, selected),
          model: chosen_model,
          key: key,
          total_timeout: total,
          connect_timeout: number("TINA4_AI_CONNECT_TIMEOUT", 10, 0.001),
          max_retries: number("TINA4_AI_MAX_RETRIES", 2, 0).to_i
        }
      rescue ArgumentError, TypeError
        raise AiConfigError, "AI timeout must be numeric"
      end

      def endpoint(value, capability, provider)
        uri = URI.parse(value)
        raise AiConfigError, "AI URL must be an http or https URL" unless %w[http https].include?(uri.scheme) && uri.host

        path = uri.path.to_s.sub(%r{/+$}, "")
        if ["", "/v1", "/api"].include?(path)
          suffix = provider == "anthropic" ? "/messages" : (capability == "embed" ? "/embeddings" : "/chat/completions")
          uri.path = (path.empty? ? "/v1" : path) + suffix
        end
        uri.to_s
      rescue URI::InvalidURIError
        raise AiConfigError, "AI URL must be an http or https URL"
      end

      def headers(config)
        result = { "Content-Type" => "application/json", "Accept" => "application/json" }
        if config[:provider] == "openai"
          result["Authorization"] = "Bearer #{config[:key]}"
        elsif config[:provider] == "anthropic"
          result["x-api-key"] = config[:key]
          result["anthropic-version"] = "2023-06-01"
        end
        result
      end

      # ── request body ───────────────────────────────────────────────────────

      def chat_body(config, messages, temperature, max_tokens, stream)
        provider = config[:provider]
        normalized = messages.map do |message|
          role = (message[:role] || message["role"]).to_s
          content = message.key?(:content) ? message[:content] : message["content"]
          { role: role, content: translate_content(provider, role, content) }
        end
        body = { model: config[:model], messages: normalized, stream: stream }
        body[:temperature] = temperature unless temperature.nil?
        body[:max_tokens] = max_tokens unless max_tokens.nil?
        if provider == "anthropic"
          system_texts = normalized.select { |message| message[:role] == "system" }.map { |message| system_text(message[:content]) }
          body[:messages] = normalized.reject { |message| message[:role] == "system" }
          body[:max_tokens] = max_tokens || 1024
          body[:system] = system_texts.join("\n\n") unless system_texts.empty?
        end
        body
      end

      # Anthropic's `system` field is a plain string. If the caller passed a
      # parts array on a system message, concatenate the text parts (image
      # parts on the system role are silently dropped — Anthropic rejects them
      # outright, and validation already ran, so we don't raise a second time).
      def system_text(content)
        return content.to_s unless content.is_a?(Array)

        content.select { |part| (part[:type] || part["type"]).to_s == "text" }
               .map { |part| part[:text] || part["text"] }.join("\n\n")
      end

      # Translate parts to each provider's native shape. Strings pass through
      # unchanged. See ADR-0060 §Public surface.
      def translate_content(provider, role, content)
        return content if content.is_a?(String)
        return system_text(content) if provider == "anthropic" && role == "system"

        content.map do |part|
          type = (part[:type] || part["type"]).to_s
          case type
          when "text"
            { type: "text", text: part[:text] || part["text"] }
          when "image"
            translate_image_part(provider, part[:source] || part["source"])
          end
        end
      end

      def translate_image_part(provider, source)
        if provider == "anthropic"
          if source.start_with?("data:")
            media_type, payload = split_data_uri(source)
            { type: "image", source: { type: "base64", media_type: media_type, data: payload } }
          else
            { type: "image", source: { type: "url", url: source } }
          end
        else
          # openai and local both accept the OpenAI image_url shape
          { type: "image_url", image_url: { url: source } }
        end
      end

      def split_data_uri(source)
        # "data:image/png;base64,<payload>"
        header, payload = source.split(",", 2)
        meta = header.to_s.sub(/\Adata:/, "")
        media_type = meta.split(";").first.to_s
        media_type = "application/octet-stream" if media_type.empty?
        [media_type, payload.to_s]
      end

      # ── non-streaming request path ─────────────────────────────────────────

      def http_request(config, deadline, request_headers, body)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise AiTimeoutError, "AI total request timeout expired" unless remaining.positive?

        uri = URI.parse(config[:url])
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.open_timeout = [config[:connect_timeout], remaining].min
        http.read_timeout = remaining
        http.write_timeout = remaining if http.respond_to?(:write_timeout=)
        request = Net::HTTP::Post.new(uri.request_uri, request_headers)
        request.body = JSON.generate(body)
        [http, request]
      end

      def request_json(config, request_headers, body)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + config[:total_timeout]
        (config[:max_retries] + 1).times do |attempt|
          begin
            http, request = http_request(config, deadline, request_headers, body)
            response = http.request(request)
            raise AiTimeoutError, "AI total request timeout expired" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            status = response.code.to_i
            unless status.between?(200, 299)
              if (status == 429 || status >= 500) && attempt < config[:max_retries]
                retry_delay(response, deadline)
                next
              end
              raise AiHTTPError.new("AI provider returned HTTP #{status}", status)
            end
            parsed = JSON.parse(response.body)
            raise AiParseError, "AI provider returned a non-object JSON response" unless parsed.is_a?(Hash)

            return parsed
          rescue Net::OpenTimeout
            raise AiTimeoutError, "AI connection timeout expired" if attempt >= config[:max_retries]
          rescue Net::ReadTimeout, Timeout::Error
            raise AiTimeoutError, "AI total request timeout expired" if attempt >= config[:max_retries]
          rescue AiHTTPError => e
            raise if e.status || attempt >= config[:max_retries]
          rescue SocketError, EOFError, IOError, SystemCallError => e
            raise AiHTTPError, "AI transport failed (#{e.class.name})" if attempt >= config[:max_retries]
          rescue JSON::ParserError
            raise AiParseError, "AI provider returned malformed JSON"
          end
        end
        raise AiHTTPError, "AI request failed"
      end

      def retry_delay(response, deadline)
        requested = Float(response["retry-after"] || 0.1) rescue 0.1
        delay = [requested.positive? ? requested : 0, deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)].min
        sleep(delay) if delay.positive?
      end

      # ── response normalisation ─────────────────────────────────────────────

      def normalize_chat(provider, raw)
        if provider == "anthropic"
          parts = raw.fetch("content").select { |item| item.fetch("type", "text") == "text" }.map { |item| item.fetch("text") }
          raise KeyError if parts.empty?

          prompt = raw.fetch("usage", {}).fetch("input_tokens", 0).to_i
          completion = raw.fetch("usage", {}).fetch("output_tokens", 0).to_i
          return ChatResponse.new(text: parts.join, model: raw.fetch("model", "").to_s,
                                  usage: { prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion },
                                  finish_reason: raw["stop_reason"], raw: raw)
        end
        choice = raw.fetch("choices").fetch(0)
        text = choice.fetch("message").fetch("content")
        raise TypeError unless text.is_a?(String)

        usage = raw.fetch("usage", {})
        ChatResponse.new(text: text, model: raw.fetch("model", "").to_s,
                         usage: { prompt_tokens: usage.fetch("prompt_tokens", 0).to_i,
                                  completion_tokens: usage.fetch("completion_tokens", 0).to_i,
                                  total_tokens: usage.fetch("total_tokens", 0).to_i },
                         finish_reason: choice["finish_reason"], raw: raw)
      rescue KeyError, IndexError, TypeError
        raise AiParseError, "AI provider returned a malformed chat response"
      end

      # ── streaming (ADR-0060 typed events, built on Api#stream_sse) ─────────

      # Split the resolved provider URL into (origin, request_uri) so we can
      # hand an Api client the origin and a path -- Api#build_uri concatenates
      # them without further munging.
      def split_url(url)
        uri = URI.parse(url)
        origin = "#{uri.scheme}://#{uri.host}"
        origin += ":#{uri.port}" if uri.port
        [origin, uri.request_uri]
      end

      def stream_events(config, request_headers, body)
        Enumerator.new do |yielder|
          stream_pump(config, request_headers, body, yielder)
        end
      end

      def stream_pump(config, request_headers, body, yielder)
        provider = config[:provider]
        origin, request_path = split_url(config[:url])
        api = Tina4::API.new(origin, timeout: config[:total_timeout])
        stream_headers = request_headers.merge("Accept" => "text/event-stream")
        request_body_json = JSON.generate(body)

        state = {
          text_delta_seen: false,
          done_emitted: false,
          error_emitted: false,
          finish_reason: nil,
          openai_tool_calls: {},         # index -> { id:, name:, args_fragments: [] }
          anthropic_tool_blocks: {}      # index -> { id:, name:, args_fragments: [] }
        }

        begin
          catch(:tina4_ai_stream_end) do
            api.stream_sse(
              request_path,
              method: "POST",
              body: request_body_json,
              headers: stream_headers,
              content_type: "application/json",
              timeout: config[:total_timeout],
              connect_timeout: config[:connect_timeout]
            ) do |sse|
              handle_sse_event(provider, sse, yielder, state)
            end
          end

          # No terminal done/error was emitted -- treat as mid-stream failure.
          emit_error(yielder, state, "AI provider stream ended before terminal event") unless state[:done_emitted] || state[:error_emitted]
        rescue Tina4::APIStreamError => e
          # Pre-stream HTTP error (status arrived before any bytes). Contract:
          # raise, not error-event. Body is not surfaced (never leak secrets).
          raise AiHTTPError.new("AI provider returned HTTP #{e.status}", e.status)
        rescue Net::OpenTimeout
          raise AiTimeoutError, "AI connection timeout expired"
        rescue Net::ReadTimeout, Timeout::Error
          if state[:text_delta_seen]
            emit_error(yielder, state, "AI total request timeout expired")
          else
            raise AiTimeoutError, "AI total request timeout expired"
          end
        rescue AiParseError
          raise
        rescue SocketError, EOFError, IOError, SystemCallError => e
          if state[:text_delta_seen]
            emit_error(yielder, state, "AI transport failed (#{e.class.name})")
          else
            raise AiHTTPError, "AI transport failed (#{e.class.name})"
          end
        end
      end

      def handle_sse_event(provider, sse, yielder, state)
        data = sse[:data]
        return if data.nil?

        if data == "[DONE]"
          # OpenAI sentinel -- flush any pending tool_calls, then emit :done.
          flush_openai_tool_calls(yielder, state)
          emit_done(yielder, state)
          throw :tina4_ai_stream_end
        end

        return if data.empty?

        parsed = begin
          JSON.parse(data)
        rescue JSON::ParserError
          raise AiParseError, "AI provider returned malformed stream data"
        end

        if provider == "anthropic"
          handle_anthropic_event(parsed, yielder, state)
        else
          handle_openai_event(parsed, yielder, state)
        end
      end

      def handle_openai_event(parsed, yielder, state)
        choice = (parsed["choices"] || []).first
        return unless choice

        delta = choice["delta"] || {}
        content = delta["content"]
        if content.is_a?(String) && !content.empty?
          yielder << { type: :text_delta, text: content }
          state[:text_delta_seen] = true
        end

        (delta["tool_calls"] || []).each do |tool_call|
          index = tool_call["index"] || 0
          entry = state[:openai_tool_calls][index] ||= { id: nil, name: nil, args_fragments: [] }
          entry[:id] = tool_call["id"] if tool_call["id"]
          function = tool_call["function"] || {}
          entry[:name] = function["name"] if function["name"]
          entry[:args_fragments] << function["arguments"] if function["arguments"].is_a?(String)
        end

        reason = choice["finish_reason"]
        return unless reason

        state[:finish_reason] = reason
        # The definitive trigger to emit aggregated tool_calls. Some providers
        # send finish_reason=stop even when tool_calls were streamed, so flush
        # on any finish_reason -- the flush is a no-op when no calls buffered.
        flush_openai_tool_calls(yielder, state)
      end

      def handle_anthropic_event(parsed, yielder, state)
        case parsed["type"]
        when "content_block_start"
          block = parsed["content_block"] || {}
          if block["type"] == "tool_use"
            state[:anthropic_tool_blocks][parsed["index"]] = {
              id: block["id"], name: block["name"], args_fragments: []
            }
          end
        when "content_block_delta"
          delta = parsed["delta"] || {}
          case delta["type"]
          when "text_delta"
            text = delta["text"]
            if text.is_a?(String) && !text.empty?
              yielder << { type: :text_delta, text: text }
              state[:text_delta_seen] = true
            end
          when "input_json_delta"
            entry = state[:anthropic_tool_blocks][parsed["index"]]
            entry[:args_fragments] << (delta["partial_json"] || "") if entry
          end
        when "content_block_stop"
          entry = state[:anthropic_tool_blocks].delete(parsed["index"])
          emit_anthropic_tool_call(yielder, entry) if entry
        when "message_delta"
          reason = (parsed["delta"] || {})["stop_reason"]
          state[:finish_reason] = reason if reason
        when "message_stop"
          emit_done(yielder, state)
          throw :tina4_ai_stream_end
        end
      end

      def flush_openai_tool_calls(yielder, state)
        state[:openai_tool_calls].keys.sort.each do |index|
          entry = state[:openai_tool_calls][index]
          joined = entry[:args_fragments].join
          args = parse_tool_args(joined)
          yielder << { type: :tool_call, id: entry[:id].to_s, name: entry[:name].to_s, args: args }
        end
        state[:openai_tool_calls].clear
      end

      def emit_anthropic_tool_call(yielder, entry)
        joined = entry[:args_fragments].join
        args = parse_tool_args(joined)
        yielder << { type: :tool_call, id: entry[:id].to_s, name: entry[:name].to_s, args: args }
      end

      def parse_tool_args(joined)
        return {} if joined.nil? || joined.empty?

        JSON.parse(joined)
      rescue JSON::ParserError
        raise AiParseError, "AI provider returned malformed tool_call arguments JSON"
      end

      def emit_done(yielder, state)
        return if state[:done_emitted] || state[:error_emitted]

        yielder << { type: :done, finish_reason: state[:finish_reason] || "stop" }
        state[:done_emitted] = true
      end

      def emit_error(yielder, state, message, code: nil)
        return if state[:done_emitted] || state[:error_emitted]

        payload = { type: :error, message: message }
        payload[:code] = code if code
        yielder << payload
        state[:error_emitted] = true
      end
    end
  end
end
