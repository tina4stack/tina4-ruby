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
                    "data: [DONE]\n\n"
                when "/stream-partial"
                  content_type = "text/event-stream"
                  "data: #{JSON.generate(choices: [{ delta: { content: 'first' } }])}\n\n"
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

  it "ai_stream_is_ordered_deltas" do
    ENV["TINA4_AI_URL"] = @server.url("/stream-openai")
    expect(Tina4::Ai.chat([{ role: "user", content: "hello" }], stream: true).to_a).to eq(["hello ", "world"])
    ENV.update("TINA4_AI_PROVIDER" => "local", "TINA4_AI_MAX_RETRIES" => "1", "TINA4_AI_URL" => @server.url("/stream-partial"))
    ENV.delete("TINA4_AI_KEY")
    expect { Tina4::Ai.chat([{ role: "user", content: "hello" }], stream: true).to_a }.to raise_error(Tina4::AiParseError)
    expect(@server.counts["/stream-partial"]).to eq(1)
    ENV.update("TINA4_AI_PROVIDER" => "anthropic", "TINA4_AI_KEY" => "hosted-key", "TINA4_AI_URL" => @server.url("/stream-anthropic"))
    expect(Tina4::Ai.chat([{ role: "user", content: "hello" }], stream: true).to_a).to eq(["hello ", "world"])
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
end
