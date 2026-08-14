# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

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

  # Zero-dependency app-facing AI client (ADR-0053).
  class Ai
    PROVIDERS = %w[local openai anthropic].freeze

    class << self
      def chat(messages, model: nil, temperature: nil, max_tokens: nil, stream: false, timeout: nil, provider: nil)
        validate_messages(messages)
        config = resolve_config("chat", model, timeout, provider)
        body = chat_body(config, messages, temperature, max_tokens, stream)
        return stream_request(config, headers(config), body) if stream

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

      def validate_messages(messages)
        valid = messages.is_a?(Array) && !messages.empty? && messages.all? do |message|
          message.is_a?(Hash) && %w[system user assistant].include?((message[:role] || message["role"]).to_s) &&
            (message.key?(:content) ? message[:content] : message["content"]).is_a?(String)
        end
        raise AiConfigError, "AI messages must contain supported roles and string content" unless valid
      end

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

      def chat_body(config, messages, temperature, max_tokens, stream)
        normalized = messages.map { |message| { role: (message[:role] || message["role"]).to_s, content: message.key?(:content) ? message[:content] : message["content"] } }
        body = { model: config[:model], messages: normalized, stream: stream }
        body[:temperature] = temperature unless temperature.nil?
        body[:max_tokens] = max_tokens unless max_tokens.nil?
        if config[:provider] == "anthropic"
          system = normalized.select { |message| message[:role] == "system" }.map { |message| message[:content] }
          body[:messages] = normalized.reject { |message| message[:role] == "system" }
          body[:max_tokens] = max_tokens || 1024
          body[:system] = system.join("\n\n") unless system.empty?
        end
        body
      end

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

      def stream_delta(provider, data)
        return [true, nil] if data == "[DONE]"

        event = JSON.parse(data)
        text = if provider == "anthropic"
                 event["type"] == "content_block_delta" ? event.dig("delta", "text") : nil
               else
                 event.dig("choices", 0, "delta", "content")
               end
        raise AiParseError, "AI provider returned malformed stream data" unless text.nil? || text.is_a?(String)

        [false, text]
      rescue JSON::ParserError
        raise AiParseError, "AI provider returned malformed stream data"
      end

      def each_stream_data(response, deadline)
        buffer = +""
        response.read_body do |chunk|
          raise AiTimeoutError, "AI total request timeout expired" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          buffer << chunk
          while (index = buffer.index("\n"))
            line = buffer.slice!(0..index).strip
            yield line.delete_prefix("data:").strip if line.start_with?("data:")
          end
        end
      end

      def stream_request(config, request_headers, body)
        Enumerator.new do |yielder|
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + config[:total_timeout]
          yielded = false
          (config[:max_retries] + 1).times do |attempt|
            begin
              http, request = http_request(config, deadline, request_headers.merge("Accept" => "text/event-stream"), body)
              retry_response = false
              completed = false
              http.request(request) do |response|
                status = response.code.to_i
                unless status.between?(200, 299)
                  response.read_body { |_chunk| nil }
                  if (status == 429 || status >= 500) && attempt < config[:max_retries]
                    retry_delay(response, deadline)
                    retry_response = true
                    next
                  end
                  raise AiHTTPError.new("AI provider returned HTTP #{status}", status)
                end
                each_stream_data(response, deadline) do |data|
                  completed, text = stream_delta(config[:provider], data)
                  break if completed
                  next if text.nil?
                  yielded = true
                  yielder << text
                end
              end
              next if retry_response
              raise AiParseError, "AI provider stream ended before [DONE]" unless completed
              break
            rescue Net::OpenTimeout
              raise AiTimeoutError, "AI connection timeout expired" if yielded || attempt >= config[:max_retries]
            rescue Net::ReadTimeout, Timeout::Error
              raise AiTimeoutError, "AI total request timeout expired" if yielded || attempt >= config[:max_retries]
            rescue SocketError, EOFError, IOError, SystemCallError => e
              raise AiHTTPError, "AI transport failed (#{e.class.name})" if yielded || attempt >= config[:max_retries]
            end
          end
        end
      end
    end
  end
end
