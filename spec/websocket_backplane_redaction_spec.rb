# frozen_string_literal: true

# SECURITY: the WebSocket backplane never writes its connection password to the log.
#
# TINA4_WS_BACKPLANE_URL carries the Redis password (redis://:secret@host/db). The
# backplane's own log lines live in lib/tina4/websocket.rb (ensure_backplane and
# publish_envelope): "WebSocket backplane active", "... wiring failed ...: <message>"
# and "... publish failed: <message>". Those <message>s come from whatever raised,
# so the question is what really reaches the log, not what the code looks like.
#
# MEASURED on the lab against the password Redis (redis://:s3cret@localhost:6381/3):
#   * good URL        -> "backplane active", no URL printed. Clean.
#   * wrong password  -> redis-client's own message is "WRONGPASS ... (redis://localhost:6381/3)",
#                        the userinfo already dropped. Clean.
#   * malformed URL   -> URI::InvalidURIError quotes the WHOLE raw URL, and
#                        ensure_backplane logged it verbatim:
#                          WebSocket backplane wiring failed, continuing local-only:
#                          bad URI(is not URI?): "redis://:s3cret@local host:xx/3"
#                        LEAK. Fixed at the source: RedisBackplane re-raises with
#                        Tina4::DatabaseUrl.redact(url), the one redaction primitive.
#   * also measured: a refused login killed the subscriber thread with only a raw
#     report_on_exception trace on stderr, while "backplane active" stood as the
#     last framework log line. The listener now logs "subscriber stopped".
#
# HOW IT IS OBSERVED, WITHOUT A DOUBLE: a REAL ruby subprocess (the bundle's own
# environment, so the real `redis` gem) drives a REAL RedisBackplane and a REAL
# Tina4::WebSocket manager against the REAL password Redis. Everything the process
# writes - the real Tina4::Log console sink on stdout, the real stderr (including the
# subscriber thread's report_on_exception trace), and any log file under its
# TINA4_LOG_DIR - is captured and searched for the password.

require_relative "spec_helper"
require "open3"
require "json"
require "tmpdir"
require "uri"
require "rbconfig"

RSpec.describe "WebSocket backplane log redaction (real password Redis)" do
  let(:repository_root) { File.expand_path("..", __dir__) }
  let(:auth_url) { ENV["TINA4_TEST_REDIS_AUTH_URL"].to_s }
  let(:password) { URI.parse(auth_url).password.to_s }

  before do
    skip "password redis not set: TINA4_TEST_REDIS_AUTH_URL not set" if auth_url.empty?
    skip "password redis TINA4_TEST_REDIS_AUTH_URL has no password - not set" if password.empty?
  end

  # A same-shape URL whose password is wrong, so the failure path is exercised.
  def wrong_password_url
    parsed = URI.parse(auth_url)
    parsed.password = "#{password}-wr0ng"
    parsed.to_s
  end

  # A URL the Redis client cannot even parse (a space in the host), still carrying
  # the REAL password. URI::InvalidURIError quotes the whole string.
  def malformed_url
    parsed = URI.parse(auth_url)
    "redis://:#{parsed.password}@#{parsed.host} host:#{parsed.port}#{parsed.path}"
  end

  def run_backplane_process(log_directory)
    source = <<~RUBY
      require "json"
      require "tina4"
      report = {}
      urls = JSON.parse(ENV.fetch("PROBE_URLS"))

      # 1. The positive: the backplane really works with this URL.
      backplane = Tina4::RedisBackplane.new(url: urls["good"])
      received = Queue.new
      channel = "tina4-redaction-\#{Process.pid}"
      backplane.subscribe(channel) { |message| received << message }
      deadline = Time.now + 5
      delivered = nil
      until delivered || Time.now > deadline
        backplane.publish(channel, "round-trip")
        delivered = received.pop(timeout: 0.25)
      end
      report["round_trip"] = delivered
      backplane.close

      # 2. Driven through the manager, exactly as a broadcast does: the good URL
      # logs "active", the wrong password logs "publish failed", the malformed
      # URL logs "wiring failed".
      ENV["TINA4_WS_BACKPLANE"] = "redis"
      %w[good wrong malformed].each do |label|
        ENV["TINA4_WS_BACKPLANE_URL"] = urls[label]
        manager = Tina4::WebSocket.new
        manager.broadcast("hello from \#{label}")
        sleep 1
        report["wired_\#{label}"] = !manager.instance_variable_get(:@backplane).nil?
      end
      puts "TINA4_REPORT \#{JSON.generate(report)}"
      $stdout.flush
      exit!(0)
    RUBY

    Dir.mktmpdir("tina4-backplane-redaction") do |sandbox|
      script = File.join(sandbox, "probe.rb")
      File.write(script, source)
      environment = {
        "PROBE_URLS" => JSON.generate("good" => auth_url, "wrong" => wrong_password_url, "malformed" => malformed_url),
        "TINA4_LOG_DIR" => log_directory,
        "TINA4_LOG_LEVEL" => "ALL",
        "TINA4_DEBUG" => "false",
        "TINA4_NO_BROWSER" => "true"
      }
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby,
                                              "-I#{File.join(repository_root, "lib")}", script,
                                              chdir: sandbox)
      files = Dir.glob(File.join(log_directory, "**", "*")).select { |path| File.file?(path) }
      file_text = files.map { |path| File.read(path) }.join("\n")
      line = stdout.lines.find { |candidate| candidate.start_with?("TINA4_REPORT ") }
      raise "backplane probe reported nothing (exit #{status.exitstatus})\n#{stdout}\n#{stderr}" if line.nil?

      [JSON.parse(line.sub("TINA4_REPORT ", "")), "#{stdout}\n#{stderr}\n#{file_text}"]
    end
  end

  it "never writes the Redis password on the working, wrong-password or malformed-URL paths" do
    Dir.mktmpdir("tina4-backplane-logs") do |log_directory|
      report, everything_written = run_backplane_process(log_directory)

      # Positive: the backplane really round-trips through the password Redis.
      expect(report["round_trip"]).to eq("round-trip")
      expect(report["wired_good"]).to be(true)

      # The three log lines this test is about really were written, so the
      # absence assertion below is about real output, not about silence.
      expect(everything_written).to include("WebSocket backplane active")
      expect(everything_written).to include("WebSocket backplane publish failed")
      expect(everything_written).to include("WebSocket backplane wiring failed")
      # The wrong-password listener's death is reported through the framework
      # log, not only as a raw thread trace on stderr.
      expect(everything_written).to include("WebSocket backplane subscriber stopped on 'tina4:ws': WRONGPASS")
      expect(report["wired_malformed"]).to be(false)

      # The malformed URL is still diagnosable: the redacted form names the host.
      host = URI.parse(auth_url).host
      expect(everything_written).to include(":***@#{host} host")

      # THE assertion: the password (real and wrong) appears nowhere.
      expect(everything_written).not_to include(password)
    end
  end
end
