# frozen_string_literal: true

require "spec_helper"
require "socket"

RSpec.describe "ADR-0053 app-facing AI client" do
  class AiContractServer
    attr_reader :port, :requests, :counts

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @requests = []
      @counts = Hash.new(0)
      @running = true
      @thread = Thread.new { serve }
    end

    def url(path)
      "http://127.0.0.1:#{port}#{path}"
    end

    def reset
      @requests.clear
      @counts.clear
    end

    def stop
      @running = false
      @server.close
      @thread.join(1)
    rescue IOError, Errno::EBADF
      nil
    end

    private

    def serve
      while @running
        socket = @server.accept
        Thread.new(socket) { |client| handle(client) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def handle(socket)
      request_line = socket.gets
      return socket.close unless request_line

      _method, path, = request_line.split
      headers = {}
      while (line = socket.gets)
        break if line == "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end
      raw_body = socket.read(headers.fetch("content-length", "0").to_i).to_s
      body = JSON.parse(raw_body.empty? ? "{}" : raw_body)
    rescue JSON::ParserError
      body = {}
    ensure
      if request_line
        # The body must be read once; rebuild it when the normal path consumed bytes.
        body ||= {}
        @requests << { path: path, body: body, authorization: headers["authorization"], x_api_key: headers["x-api-key"] }
        @counts[path] += 1
        respond(socket, path, body)
      end
    end

    def respond(socket, path, body)
      status = 200
      content_type = "application/json"
      extra = {}
      payload = case path
                when "/openai"
                  JSON.generate(model: body["model"] || "fixture-model", choices: [{ message: { content: "hello world" }, finish_reason: "stop" }], usage: { prompt_tokens: 3, completion_tokens: 2, total_tokens: 5 })
                when "/anthropic"
                  JSON.generate(model: body["model"] || "fixture-model", content: [{ type: "text", text: "hello world" }], stop_reason: "end_turn", usage: { input_tokens: 3, output_tokens: 2 })
                when "/embeddings"
                  inputs = body["input"].is_a?(Array) ? body["input"] : [body["input"]]
                  JSON.generate(data: inputs.each_index.map { |i| { index: i, embedding: [i.to_f, 0.25, 0.5] } })
                when "/stream-openai"
                  content_type = "text/event-stream"
                  "data: #{JSON.generate(choices: [{ delta: { content: 'hello ' } }])}\n\n" \
                    "data: #{JSON.generate(choices: [{ delta: { content: 'world' }, finish_reason: 'stop' }])}\n\n" \
                    "data: [DONE]\n\n"
                when "/stream-anthropic"
                  content_type = "text/event-stream"
                  "data: #{JSON.generate(type: 'content_block_delta', delta: { type: 'text_delta', text: 'hello ' })}\n\n" \
                    "data: #{JSON.generate(type: 'content_block_delta', delta: { type: 'text_delta', text: 'world' })}\n\n" \
                    "data: #{JSON.generate(type: 'message_delta', delta: { stop_reason: 'end_turn' })}\n\n" \
                    "data: #{JSON.generate(type: 'message_stop')}\n\n"
                when "/stream-openai-tools"
                  content_type = "text/event-stream"
                  # OpenAI tool_calls arrive as fragmented function.arguments
                  # strings; the client buffers them per index and emits ONE
                  # tool_call event when finish_reason=tool_calls fires.
                  "data: #{JSON.generate(choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: 'get_weather', arguments: '' } }] } }])}\n\n" \
                    "data: #{JSON.generate(choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: '{"loc' } }] } }])}\n\n" \
                    "data: #{JSON.generate(choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: 'ation":"Boston"}' } }] } }])}\n\n" \
                    "data: #{JSON.generate(choices: [{ delta: {}, finish_reason: 'tool_calls' }])}\n\n" \
                    "data: [DONE]\n\n"
                when "/stream-anthropic-tools"
                  content_type = "text/event-stream"
                  # Anthropic streams a content_block_start for the tool, then
                  # input_json_delta fragments, then content_block_stop; the
                  # client emits ONE tool_call event on stop.
                  "data: #{JSON.generate(type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 'toolu_1', name: 'get_weather', input: {} })}\n\n" \
                    "data: #{JSON.generate(type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{"loc' })}\n\n" \
                    "data: #{JSON.generate(type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: 'ation":"Boston"}' })}\n\n" \
                    "data: #{JSON.generate(type: 'content_block_stop', index: 0)}\n\n" \
                    "data: #{JSON.generate(type: 'message_delta', delta: { stop_reason: 'tool_use' })}\n\n" \
                    "data: #{JSON.generate(type: 'message_stop')}\n\n"
                when "/stream-partial"
                  content_type = "text/event-stream"
                  "data: #{JSON.generate(choices: [{ delta: { content: 'first' } }])}\n\n"
                when "/stream-midstream-drop"
                  content_type = "text/event-stream"
                  # Send one delta then hang up before [DONE]. Net::HTTP sees
                  # a Content-Length that never arrives -> transport failure
                  # after we've already yielded one text_delta.
                  extra["Content-Length"] = "9999"
                  "data: #{JSON.generate(choices: [{ delta: { content: 'partial' } }])}\n\n"
                when "/multimodal-echo"
                  # Mirrors /openai but the test asserts the request body shape.
                  JSON.generate(model: body["model"] || "fixture-model", choices: [{ message: { content: "ok" }, finish_reason: "stop" }], usage: {})
                when "/tool-echo-openai"
                  # OpenAI-shape non-streaming echo — the tests only assert
                  # the outbound request body.
                  JSON.generate(model: body["model"] || "fixture-model", choices: [{ message: { content: "ok" }, finish_reason: "stop" }], usage: {})
                when "/tool-echo-anthropic"
                  # Anthropic-shape non-streaming echo.
                  JSON.generate(model: body["model"] || "fixture-model", content: [{ type: "text", text: "ok" }], stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 })
                when "/agent-openai"
                  # Full round-trip: first call (no tool result yet) streams
                  # ONE tool_call; second call (tool result appended) streams
                  # the final text_delta + done. Both responses are OpenAI SSE.
                  content_type = "text/event-stream"
                  has_tool_result = (body["messages"] || []).any? { |m| m.is_a?(Hash) && m["role"] == "tool" }
                  if has_tool_result
                    "data: #{JSON.generate(choices: [{ delta: { content: "It is sunny in Boston." } }])}\n\n" \
                      "data: #{JSON.generate(choices: [{ delta: {}, finish_reason: "stop" }])}\n\n" \
                      "data: [DONE]\n\n"
                  else
                    "data: #{JSON.generate(choices: [{ delta: { tool_calls: [{ index: 0, id: "call_1", type: "function", function: { name: "get_weather", arguments: '{"city":"Boston"}' } }] } }])}\n\n" \
                      "data: #{JSON.generate(choices: [{ delta: {}, finish_reason: "tool_calls" }])}\n\n" \
                      "data: [DONE]\n\n"
                  end
                when "/agent-anthropic"
                  # Same round-trip against the Anthropic SSE shape.
                  content_type = "text/event-stream"
                  has_tool_result = (body["messages"] || []).any? do |m|
                    m.is_a?(Hash) && m["role"] == "user" && m["content"].is_a?(Array) &&
                      m["content"].any? { |p| p.is_a?(Hash) && p["type"] == "tool_result" }
                  end
                  if has_tool_result
                    "data: #{JSON.generate(type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "It is sunny in Boston." })}\n\n" \
                      "data: #{JSON.generate(type: "message_delta", delta: { stop_reason: "end_turn" })}\n\n" \
                      "data: #{JSON.generate(type: "message_stop")}\n\n"
                  else
                    "data: #{JSON.generate(type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_1", name: "get_weather", input: {} })}\n\n" \
                      "data: #{JSON.generate(type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"city":"Boston"}' })}\n\n" \
                      "data: #{JSON.generate(type: "content_block_stop", index: 0)}\n\n" \
                      "data: #{JSON.generate(type: "message_delta", delta: { stop_reason: "tool_use" })}\n\n" \
                      "data: #{JSON.generate(type: "message_stop")}\n\n"
                  end
                when "/retry"
                  if @counts[path] == 1
                    status = 429
                    extra["Retry-After"] = "0"
                    JSON.generate(error: "later")
                  else
                    JSON.generate(model: "retry-model", choices: [{ message: { content: "recovered" }, finish_reason: "stop" }], usage: {})
                  end
                when "/always500"
                  status = 500
                  JSON.generate(error: "provider-secret-body")
                when "/bad400"
                  status = 400
                  JSON.generate(error: "permanent")
                when "/slow"
                  sleep 0.25
                  JSON.generate(choices: [{ message: { content: "late" } }])
                when "/malformed"
                  JSON.generate(choices: [])
                else
                  status = 404
                  JSON.generate(error: "missing")
                end
      reason = status == 200 ? "OK" : "Error"
      headers = { "Content-Type" => content_type, "Content-Length" => payload.bytesize.to_s, "Connection" => "close" }.merge(extra)
      socket.write("HTTP/1.1 #{status} #{reason}\r\n#{headers.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n#{payload}")
    rescue Errno::EPIPE, IOError
      nil
    ensure
      socket.close rescue nil
    end
  end

  class AiStallServer
    attr_reader :port

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @clients = []
      @running = true
      @thread = Thread.new do
        while @running
          @clients << @server.accept
        end
      rescue IOError, Errno::EBADF
        nil
      end
    end

    def stop
      @running = false
      @server.close
      @clients.each { |client| client.close rescue nil }
      @thread.join(1)
    end
  end

  before(:all) do
    @server = AiContractServer.new
    @stall_server = AiStallServer.new
  end
  after(:all) do
    @server.stop
    @stall_server.stop
  end

  before do
    ENV.keys.grep(/\ATINA4_AI_|\ATINA4_EMBED_URL\z/).each { |key| ENV.delete(key) }
    ENV["TINA4_AI_MODEL"] = "env-model"
    ENV["TINA4_AI_TIMEOUT"] = "2"
    ENV["TINA4_AI_CONNECT_TIMEOUT"] = "1"
    ENV["TINA4_AI_MAX_RETRIES"] = "0"
    @server.reset
  end

  it "ai_public_surface" do
    ENV["TINA4_AI_URL"] = @server.url("/openai")
    expect(Tina4::Ai.chat([{ role: "user", content: "hello" }])).to be_a(Tina4::ChatResponse)
    expect(Tina4::Ai.complete("hello")).to eq("hello world")
    ENV["TINA4_EMBED_URL"] = @server.url("/embeddings")
    expect(Tina4::Ai.embed("hello")).to eq([0.0, 0.25, 0.5])
    expect(Tina4::Ai).not_to respond_to(:ask, :ask_json, :vision, :image)
  end

  it "ai_chat_response_normalized" do
    ENV["TINA4_AI_URL"] = @server.url("/openai")
    result = Tina4::Ai.chat([{ role: "user", content: "hello" }], model: "call-model")
    expect([result.text, result.model, result.finish_reason]).to eq(["hello world", "call-model", "stop"])
    expect(result.usage).to eq(prompt_tokens: 3, completion_tokens: 2, total_tokens: 5)
    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key", "TINA4_AI_URL" => @server.url("/anthropic"))
    result = Tina4::Ai.chat([{ role: "user", content: "hello" }])
    expect([result.text, result.usage[:total_tokens], result.finish_reason]).to eq(["hello world", 5, "end_turn"])
  end

  it "ai_complete_is_single_turn_text" do
    ENV["TINA4_AI_URL"] = @server.url("/openai")
    expect(Tina4::Ai.complete("only this")).to eq("hello world")
    expect(@server.requests.last[:body]["messages"]).to eq([{ "role" => "user", "content" => "only this" }])
  end

  it "ai_embedding_cardinality" do
    ENV["TINA4_EMBED_URL"] = @server.url("/embeddings")
    expect(Tina4::Ai.embed("one")).to eq([0.0, 0.25, 0.5])
    expect(Tina4::Ai.embed(%w[one two])).to eq([[0.0, 0.25, 0.5], [1.0, 0.25, 0.5]])
  end

  # ── ADR-0060: typed streaming events ────────────────────────────────────

  it "ai-stream-text-deltas-order" do
    ENV["TINA4_AI_URL"] = @server.url("/stream-openai")
    events = Tina4::Ai.chat([{ role: "user", content: "hello" }], stream: true).to_a
    texts = events.select { |e| e[:type] == :text_delta }.map { |e| e[:text] }
    expect(texts).to eq(["hello ", "world"])

    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/stream-anthropic"))
    events = Tina4::Ai.chat([{ role: "user", content: "hi" }], stream: true).to_a
    texts = events.select { |e| e[:type] == :text_delta }.map { |e| e[:text] }
    expect(texts).to eq(["hello ", "world"])
  end

  it "ai-stream-tool-call-aggregated-openai" do
    ENV["TINA4_AI_URL"] = @server.url("/stream-openai-tools")
    events = Tina4::Ai.chat([{ role: "user", content: "call it" }], stream: true).to_a
    tool_calls = events.select { |e| e[:type] == :tool_call }
    expect(tool_calls.length).to eq(1)
    expect(tool_calls.first).to include(id: "call_1", name: "get_weather",
                                        args: { "location" => "Boston" })
    # Exactly one tool_call event -- fragmented args were aggregated, not
    # emitted per fragment.
    expect(events.count { |e| e[:type] == :tool_call }).to eq(1)
  end

  it "ai-stream-tool-call-aggregated-anthropic" do
    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/stream-anthropic-tools"))
    events = Tina4::Ai.chat([{ role: "user", content: "call it" }], stream: true).to_a
    tool_calls = events.select { |e| e[:type] == :tool_call }
    expect(tool_calls.length).to eq(1)
    expect(tool_calls.first).to include(id: "toolu_1", name: "get_weather",
                                        args: { "location" => "Boston" })
  end

  it "ai-stream-done-fires-once" do
    ENV["TINA4_AI_URL"] = @server.url("/stream-openai")
    events = Tina4::Ai.chat([{ role: "user", content: "hello" }], stream: true).to_a
    done = events.select { |e| e[:type] == :done }
    expect(done.length).to eq(1)
    expect(done.first[:finish_reason]).to eq("stop")
    # done is the LAST event.
    expect(events.last[:type]).to eq(:done)

    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/stream-anthropic"))
    events = Tina4::Ai.chat([{ role: "user", content: "hi" }], stream: true).to_a
    done = events.select { |e| e[:type] == :done }
    expect(done.length).to eq(1)
    expect(done.first[:finish_reason]).to eq("end_turn")
    expect(events.last[:type]).to eq(:done)
  end

  it "ai-stream-error-instead-of-done-on-midstream-failure" do
    ENV["TINA4_AI_URL"] = @server.url("/stream-partial")
    events = Tina4::Ai.chat([{ role: "user", content: "hello" }], stream: true).to_a
    # We got at least one text_delta, then no terminal SSE event -> :error.
    expect(events.count { |e| e[:type] == :text_delta }).to be >= 1
    expect(events.count { |e| e[:type] == :done }).to eq(0)
    expect(events.last[:type]).to eq(:error)
    expect(events.last[:message]).to be_a(String)
  end

  it "ai-stream-no-retry-after-first-event" do
    ENV["TINA4_AI_MAX_RETRIES"] = "3"
    ENV["TINA4_AI_URL"] = @server.url("/stream-partial")
    Tina4::Ai.chat([{ role: "user", content: "hello" }], stream: true).to_a
    # Once we yielded a delta, the client MUST NOT reissue the request even
    # though the stream ended before [DONE] and retries are configured.
    expect(@server.counts["/stream-partial"]).to eq(1)
  end

  # ── ADR-0060: multimodal content parts ──────────────────────────────────

  it "ai-multimodal-text-part" do
    ENV["TINA4_AI_URL"] = @server.url("/multimodal-echo")
    Tina4::Ai.chat([{ role: "user",
                      content: [{ type: "text", text: "hello" }] }])
    sent = @server.requests.last[:body]
    expect(sent["messages"].first["content"]).to eq([{ "type" => "text", "text" => "hello" }])
  end

  it "ai-multimodal-image-data-uri" do
    ENV["TINA4_AI_URL"] = @server.url("/multimodal-echo")
    data_uri = "data:image/png;base64,iVBORw0KGgoAAAA="
    Tina4::Ai.chat([{ role: "user",
                      content: [{ type: "text", text: "what is this?" },
                                { type: "image", source: data_uri }] }])
    parts = @server.requests.last[:body]["messages"].first["content"]
    expect(parts.first).to eq("type" => "text", "text" => "what is this?")
    expect(parts.last).to eq("type" => "image_url", "image_url" => { "url" => data_uri })
  end

  it "ai-multimodal-image-url" do
    ENV["TINA4_AI_URL"] = @server.url("/multimodal-echo")
    url = "https://example.com/cat.png"
    Tina4::Ai.chat([{ role: "user",
                      content: [{ type: "image", source: url }] }])
    parts = @server.requests.last[:body]["messages"].first["content"]
    expect(parts).to eq([{ "type" => "image_url", "image_url" => { "url" => url } }])
  end

  it "ai-multimodal-malformed-part-fails-config" do
    ENV["TINA4_AI_URL"] = @server.url("/multimodal-echo")
    # Missing text
    expect do
      Tina4::Ai.chat([{ role: "user", content: [{ type: "text" }] }])
    end.to raise_error(Tina4::AiConfigError)
    # Unknown type
    expect do
      Tina4::Ai.chat([{ role: "user", content: [{ type: "video", source: "https://x/" }] }])
    end.to raise_error(Tina4::AiConfigError)
    # Non-string text
    expect do
      Tina4::Ai.chat([{ role: "user", content: [{ type: "text", text: 42 }] }])
    end.to raise_error(Tina4::AiConfigError)
    # data URI without base64 marker
    expect do
      Tina4::Ai.chat([{ role: "user", content: [{ type: "image", source: "data:image/png,abc" }] }])
    end.to raise_error(Tina4::AiConfigError)
    # http URL (must be https or data)
    expect do
      Tina4::Ai.chat([{ role: "user", content: [{ type: "image", source: "http://x/" }] }])
    end.to raise_error(Tina4::AiConfigError)
    # Not a Hash part
    expect do
      Tina4::Ai.chat([{ role: "user", content: ["hello"] }])
    end.to raise_error(Tina4::AiConfigError)
    # Empty parts array
    expect do
      Tina4::Ai.chat([{ role: "user", content: [] }])
    end.to raise_error(Tina4::AiConfigError)
    # None of the requests reached the wire.
    expect(@server.requests).to be_empty
  end

  it "ai-multimodal-openai-body-shape" do
    ENV["TINA4_AI_URL"] = @server.url("/multimodal-echo")
    data_uri = "data:image/jpeg;base64,ABCDEF=="
    Tina4::Ai.chat([{ role: "user",
                      content: [{ type: "text", text: "what is this?" },
                                { type: "image", source: data_uri }] }])
    body = @server.requests.last[:body]
    expect(body["messages"]).to eq([{
      "role" => "user",
      "content" => [
        { "type" => "text", "text" => "what is this?" },
        { "type" => "image_url", "image_url" => { "url" => data_uri } }
      ]
    }])
  end

  it "ai-multimodal-anthropic-body-shape" do
    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/anthropic"))
    data_uri = "data:image/png;base64,ZXhhbXBsZQ=="
    Tina4::Ai.chat([{ role: "user",
                      content: [{ type: "text", text: "describe" },
                                { type: "image", source: data_uri },
                                { type: "image", source: "https://example.com/img.jpg" }] }])
    body = @server.requests.last[:body]
    parts = body["messages"].first["content"]
    expect(parts[0]).to eq("type" => "text", "text" => "describe")
    expect(parts[1]).to eq("type" => "image", "source" => {
                            "type" => "base64", "media_type" => "image/png", "data" => "ZXhhbXBsZQ=="
                          })
    expect(parts[2]).to eq("type" => "image", "source" => {
                            "type" => "url", "url" => "https://example.com/img.jpg"
                          })
  end

  it "ai_configuration_precedence" do
    ENV["TINA4_AI_URL"] = @server.url("/openai")
    Tina4::Ai.chat([{ role: "user", content: "hello" }], model: "call-model", temperature: 0.2, max_tokens: 9)
    expect(@server.requests.last[:body]).to include("model" => "call-model", "temperature" => 0.2, "max_tokens" => 9)
  end

  it "ai_hosted_key_fails_closed_and_redacted" do
    ENV.update("TINA4_AI_PROVIDER" => "openai", "TINA4_AI_URL" => @server.url("/openai"))
    expect { Tina4::Ai.chat([{ role: "user", content: "private prompt" }]) }.to raise_error(Tina4::AiConfigError)
    expect(@server.requests).to be_empty
    ENV.update("TINA4_AI_KEY" => "super-secret-key", "TINA4_AI_URL" => @server.url("/always500"))
    expect { Tina4::Ai.chat([{ role: "user", content: "private prompt" }]) }.to raise_error(Tina4::AiHTTPError) { |error|
      expect(error.message).not_to include("super-secret-key", "private prompt", "provider-secret-body")
    }
  end

  it "ai_retries_only_safe_transients" do
    ENV.update("TINA4_AI_MAX_RETRIES" => "1", "TINA4_AI_URL" => @server.url("/retry"))
    expect(Tina4::Ai.complete("hello")).to eq("recovered")
    ENV["TINA4_AI_URL"] = @server.url("/bad400")
    expect { Tina4::Ai.complete("hello") }.to raise_error(Tina4::AiHTTPError)
    expect(@server.counts.values_at("/retry", "/bad400")).to eq([2, 1])
  end

  it "ai_timeouts_are_distinct_and_bounded" do
    ENV["TINA4_AI_URL"] = @server.url("/slow")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { Tina4::Ai.chat([{ role: "user", content: "hello" }], timeout: 0.05) }.to raise_error(Tina4::AiTimeoutError, /total/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    ENV["TINA4_AI_URL"] = "https://127.0.0.1:#{@stall_server.port}/stall"
    ENV["TINA4_AI_CONNECT_TIMEOUT"] = "0.05"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { Tina4::Ai.chat([{ role: "user", content: "hello" }], timeout: 1) }.to raise_error(Tina4::AiTimeoutError, /connection/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    expect { Tina4::Ai.chat([{ role: "user", content: "hello" }], timeout: 0) }.to raise_error(Tina4::AiConfigError)
  end

  it "ai_zero_runtime_dependencies_real_socket" do
    ENV["TINA4_AI_URL"] = @server.url("/malformed")
    expect { Tina4::Ai.chat([{ role: "user", content: "hello" }]) }.to raise_error(Tina4::AiParseError)
  end

  # ── ADR-0061: outbound tools declaration ────────────────────────────────

  it "ai-tools-openai-body-shape" do
    ENV["TINA4_AI_URL"] = @server.url("/tool-echo-openai")
    tools = [{
      name: "get_weather",
      description: "Get the weather",
      parameters: { type: "object",
                    properties: { city: { type: "string" } },
                    required: ["city"] }
    }]
    Tina4::Ai.chat([{ role: "user", content: "weather?" }], tools: tools)
    sent = @server.requests.last[:body]
    expect(sent["tools"]).to eq([{
      "type" => "function",
      "function" => {
        "name" => "get_weather",
        "description" => "Get the weather",
        "parameters" => { "type" => "object",
                          "properties" => { "city" => { "type" => "string" } },
                          "required" => ["city"] }
      }
    }])
  end

  it "ai-tools-anthropic-body-shape" do
    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/tool-echo-anthropic"))
    tools = [{
      name: "get_weather",
      description: "Get the weather",
      parameters: { type: "object",
                    properties: { city: { type: "string" } },
                    required: ["city"] }
    }]
    Tina4::Ai.chat([{ role: "user", content: "weather?" }], tools: tools)
    sent = @server.requests.last[:body]
    expect(sent["tools"]).to eq([{
      "name" => "get_weather",
      "description" => "Get the weather",
      "input_schema" => { "type" => "object",
                          "properties" => { "city" => { "type" => "string" } },
                          "required" => ["city"] }
    }])
  end

  it "ai-tools-parameters-passthrough-jsonschema" do
    ENV["TINA4_AI_URL"] = @server.url("/tool-echo-openai")
    schema = {
      type: "object",
      properties: {
        query: { type: "string", description: "search text" },
        limit: { type: "integer", minimum: 1, maximum: 50, default: 10 },
        filters: {
          type: "object",
          properties: { since: { type: "string", format: "date-time" } },
          additionalProperties: false
        }
      },
      required: ["query"],
      additionalProperties: false
    }
    Tina4::Ai.chat([{ role: "user", content: "find" }],
                   tools: [{ name: "search", description: "run a search", parameters: schema }])
    sent_params = @server.requests.last[:body]["tools"].first["function"]["parameters"]
    expect(sent_params).to eq(JSON.parse(JSON.generate(schema)))
  end

  # ── ADR-0061: tool_choice mode translation ──────────────────────────────

  it "ai-tool-choice-auto" do
    ENV["TINA4_AI_URL"] = @server.url("/tool-echo-openai")
    Tina4::Ai.chat([{ role: "user", content: "hi" }],
                   tools: [{ name: "t", description: "t", parameters: { type: "object" } }],
                   tool_choice: "auto")
    expect(@server.requests.last[:body]["tool_choice"]).to eq("auto")

    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/tool-echo-anthropic"))
    Tina4::Ai.chat([{ role: "user", content: "hi" }],
                   tools: [{ name: "t", description: "t", parameters: { type: "object" } }],
                   tool_choice: :auto)
    expect(@server.requests.last[:body]["tool_choice"]).to eq("type" => "auto")
  end

  it "ai-tool-choice-none" do
    ENV["TINA4_AI_URL"] = @server.url("/tool-echo-openai")
    Tina4::Ai.chat([{ role: "user", content: "hi" }],
                   tools: [{ name: "t", description: "t", parameters: { type: "object" } }],
                   tool_choice: "none")
    body = @server.requests.last[:body]
    expect(body["tool_choice"]).to eq("none")
    expect(body["tools"]).to be_a(Array)   # OpenAI keeps the tools list even when tool_choice is "none"

    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/tool-echo-anthropic"))
    Tina4::Ai.chat([{ role: "user", content: "hi" }],
                   tools: [{ name: "t", description: "t", parameters: { type: "object" } }],
                   tool_choice: "none")
    body = @server.requests.last[:body]
    # Anthropic has no "none" — the whole tool surface is omitted.
    expect(body).not_to have_key("tools")
    expect(body).not_to have_key("tool_choice")
  end

  it "ai-tool-choice-required" do
    ENV["TINA4_AI_URL"] = @server.url("/tool-echo-openai")
    Tina4::Ai.chat([{ role: "user", content: "hi" }],
                   tools: [{ name: "t", description: "t", parameters: { type: "object" } }],
                   tool_choice: "required")
    expect(@server.requests.last[:body]["tool_choice"]).to eq("required")

    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/tool-echo-anthropic"))
    Tina4::Ai.chat([{ role: "user", content: "hi" }],
                   tools: [{ name: "t", description: "t", parameters: { type: "object" } }],
                   tool_choice: "required")
    expect(@server.requests.last[:body]["tool_choice"]).to eq("type" => "any")
  end

  it "ai-tool-choice-named" do
    ENV["TINA4_AI_URL"] = @server.url("/tool-echo-openai")
    Tina4::Ai.chat([{ role: "user", content: "hi" }],
                   tools: [{ name: "get_weather", description: "w", parameters: { type: "object" } }],
                   tool_choice: { name: "get_weather" })
    expect(@server.requests.last[:body]["tool_choice"]).to eq(
      "type" => "function", "function" => { "name" => "get_weather" }
    )

    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/tool-echo-anthropic"))
    Tina4::Ai.chat([{ role: "user", content: "hi" }],
                   tools: [{ name: "get_weather", description: "w", parameters: { type: "object" } }],
                   tool_choice: { "name" => "get_weather" })
    expect(@server.requests.last[:body]["tool_choice"]).to eq(
      "type" => "tool", "name" => "get_weather"
    )
  end

  # ── ADR-0061: tool-result message shape ─────────────────────────────────

  it "ai-tool-result-openai-form-passthrough" do
    ENV["TINA4_AI_URL"] = @server.url("/tool-echo-openai")
    Tina4::Ai.chat([
      { role: "user", content: "weather?" },
      { role: "tool", tool_call_id: "call_1", content: "sunny 24C" }
    ])
    messages = @server.requests.last[:body]["messages"]
    expect(messages.last).to eq(
      "role" => "tool", "tool_call_id" => "call_1", "content" => "sunny 24C"
    )
  end

  it "ai-tool-result-anthropic-form-passthrough" do
    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/tool-echo-anthropic"))
    Tina4::Ai.chat([
      { role: "user", content: "weather?" },
      { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "sunny 24C" }] }
    ])
    messages = @server.requests.last[:body]["messages"]
    expect(messages.last).to eq(
      "role" => "user",
      "content" => [{ "type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "sunny 24C" }]
    )
  end

  it "ai-tool-result-openai-to-anthropic-translation" do
    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/tool-echo-anthropic"))
    Tina4::Ai.chat([
      { role: "user", content: "weather?" },
      { role: "tool", tool_call_id: "call_1", content: "sunny 24C" }
    ])
    messages = @server.requests.last[:body]["messages"]
    # OpenAI-form tool message was translated into an Anthropic user turn
    # carrying a tool_result part.
    expect(messages.last).to eq(
      "role" => "user",
      "content" => [{ "type" => "tool_result", "tool_use_id" => "call_1", "content" => "sunny 24C" }]
    )
    expect(messages.none? { |m| m["role"] == "tool" }).to be(true)
  end

  it "ai-tool-result-anthropic-to-openai-translation" do
    ENV["TINA4_AI_URL"] = @server.url("/tool-echo-openai")
    Tina4::Ai.chat([
      { role: "user", content: "weather?" },
      { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "sunny 24C" }] }
    ])
    messages = @server.requests.last[:body]["messages"]
    # Anthropic user+tool_result turn was translated into a flat OpenAI tool
    # message with the tool_call_id set to the tool_use_id.
    expect(messages.last).to eq(
      "role" => "tool", "tool_call_id" => "toolu_1", "content" => "sunny 24C"
    )
    # And there is no leftover user message with a tool_result content part.
    expect(messages.none? { |m| m["role"] == "user" && m["content"].is_a?(Array) && m["content"].any? { |p| p["type"] == "tool_result" } }).to be(true)
  end

  # ── ADR-0061: full agent-loop round-trip ────────────────────────────────

  it "ai-agent-loop-openai-round-trip" do
    ENV["TINA4_AI_URL"] = @server.url("/agent-openai")
    tools = [{ name: "get_weather", description: "Get the weather",
               parameters: { type: "object",
                             properties: { city: { type: "string" } },
                             required: ["city"] } }]

    messages = [{ role: "user", content: "what is the weather in Boston?" }]

    # Turn 1 — send messages + tools; the model streams ONE tool_call and done.
    events = Tina4::Ai.chat(messages, stream: true, tools: tools).to_a
    tool_call = events.find { |e| e[:type] == :tool_call }
    expect(tool_call).to include(id: "call_1", name: "get_weather", args: { "city" => "Boston" })
    expect(events.last[:type]).to eq(:done)

    # Caller "runs" the tool locally.
    result = "sunny 24C"

    # Turn 2 — append the assistant tool_calls message + tool result, resend.
    messages << { role: "assistant", content: nil,
                  tool_calls: [{ id: tool_call[:id], type: "function",
                                 function: { name: tool_call[:name], arguments: JSON.generate(tool_call[:args]) } }] }
    messages << { role: "tool", tool_call_id: tool_call[:id], content: result }

    events2 = Tina4::Ai.chat(messages, stream: true, tools: tools).to_a
    text = events2.select { |e| e[:type] == :text_delta }.map { |e| e[:text] }.join
    expect(text).to eq("It is sunny in Boston.")
    expect(events2.last[:type]).to eq(:done)
    expect(events2.last[:finish_reason]).to eq("stop")

    # And the fixture server saw both turns.
    expect(@server.counts["/agent-openai"]).to eq(2)
  end

  it "ai-agent-loop-anthropic-round-trip" do
    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key",
               "TINA4_AI_URL" => @server.url("/agent-anthropic"))
    tools = [{ name: "get_weather", description: "Get the weather",
               parameters: { type: "object",
                             properties: { city: { type: "string" } },
                             required: ["city"] } }]

    messages = [{ role: "user", content: "what is the weather in Boston?" }]

    events = Tina4::Ai.chat(messages, stream: true, tools: tools).to_a
    tool_call = events.find { |e| e[:type] == :tool_call }
    expect(tool_call).to include(id: "toolu_1", name: "get_weather", args: { "city" => "Boston" })
    expect(events.last[:type]).to eq(:done)

    result = "sunny 24C"

    # Anthropic-form return: append a user message with a tool_result part.
    messages << { role: "user",
                  content: [{ type: "tool_result", tool_use_id: tool_call[:id], content: result }] }

    events2 = Tina4::Ai.chat(messages, stream: true, tools: tools).to_a
    text = events2.select { |e| e[:type] == :text_delta }.map { |e| e[:text] }.join
    expect(text).to eq("It is sunny in Boston.")
    expect(events2.last[:type]).to eq(:done)
    expect(events2.last[:finish_reason]).to eq("end_turn")

    expect(@server.counts["/agent-anthropic"]).to eq(2)
  end
end
