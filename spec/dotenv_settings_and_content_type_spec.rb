# frozen_string_literal: true

# Regression lock-in for tina4-python#143 and #144 across the family (ADR-0072).
#
# #144: a Content-Type set with response.header() is THE Content-Type. Ruby
# stored header("Content-Type", ...) under its own hash key next to the
# "content-type" key call() sets, so Puma sent BOTH (text/html and image/png),
# and header("content-type", ...) was overwritten by call()'s detected type.
#
# #143: a setting in .env applies. Ruby already read TINA4_MAX_UPLOAD_SIZE when
# it was used; these cases lock that in beside the other three frameworks.
#
# NO MOCKS: a real `ruby app.rb` booted by Tina4.run! from a project whose .env
# carries the settings (the outer environment is scrubbed of them), on BOTH
# servers production can pick - Tina4's built-in server, and Puma when the
# application bundles it (ADR-0067) - and every case is a real HTTP request over
# a real loopback socket, with repeated headers read raw.

require "spec_helper"
require "net/http"
require "open3"
require_relative "support/shutdown_probe"

RSpec.describe "Dotenv settings and header Content-Type (ADR-0072)" do
  upload_limit = 1000
  dotenv_health_path = "/healthz-from-dotenv"

  def write_project(dir, upload_limit, dotenv_health_path)
    File.write(File.join(dir, ".env"),
               "TINA4_MAX_UPLOAD_SIZE=#{upload_limit}\nTINA4_HEALTH_PATH=#{dotenv_health_path}\n")
    File.write(File.join(dir, "app.rb"), <<~RUBY)
      #{ShutdownProbe.load_guard}
      png = ["89504e470d0a1a0a"].pack("H*")
      Tina4::Router.post("/upload") { |_request, response| response.call("OK", 200) }.no_auth
      Tina4::Router.get("/content-type/header-with-bytes") do |_request, response|
        response.header("Content-Type", "image/png")
        response.call(png)
      end
      Tina4::Router.get("/content-type/lowercase-header") do |_request, response|
        response.header("content-type", "image/png")
        response.call(png)
      end
      Tina4::Router.get("/content-type/header-with-string") do |_request, response|
        response.header("Content-Type", "text/csv")
        response.call("a,b")
      end
      Tina4::Router.get("/content-type/argument-after-header") do |_request, response|
        response.header("Content-Type", "image/png")
        response.call(png, 200, "image/gif")
      end
      Tina4::Router.get("/content-type/detected") { |_request, response| response.call("plain words") }
      Tina4.run!(__dir__)
    RUBY
  end

  def boot(upload_limit, dotenv_health_path, puma:)
    dir = SpecTmpdir.create("tina4-dotenv-settings")
    write_project(dir, upload_limit, dotenv_health_path)
    port = ShutdownProbe.free_port
    child_env = ShutdownProbe.base_env(
      "TINA4_OVERRIDE_CLIENT" => "true",
      "TINA4_PORT" => port.to_s, "TINA4_HOST" => "127.0.0.1", "PORT" => nil, "HOST" => nil,
      # Pin the built-in server when Puma is not wanted: a Puma installed as a
      # system gem would otherwise be picked even without an app bundle.
      "TINA4_DEFAULT_WEBSERVER" => puma ? nil : "true",
      # The settings under test must come from .env alone.
      "TINA4_MAX_UPLOAD_SIZE" => nil, "TINA4_HEALTH_PATH" => nil, "TINA4_ENV_FILE" => nil
    )
    command = [RbConfig.ruby, "app.rb"]
    if puma
      # Production picks Puma only when the APPLICATION bundles it (ADR-0067).
      File.write(File.join(dir, "Gemfile"), <<~GEMFILE)
        source "https://rubygems.org"
        gem "tina4ruby", path: #{File.expand_path("..", __dir__).inspect}
        gem "puma"
      GEMFILE
      # CI installs development gems into Bundler's isolated vendor path.
      # with_unbundled_env removes that path from the environment; retain the
      # real installed gem locations while letting this app own its Gemfile.
      child_env.merge!("BUNDLE_GEMFILE" => File.join(dir, "Gemfile"), "BUNDLE_WITH" => nil,
                       "BUNDLE_WITHOUT" => nil, "BUNDLE_FROZEN" => nil, "BUNDLE_DEPLOYMENT" => nil,
                       "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR))
      output, status = unbundled { Open3.capture2e(child_env, "bundle", "lock", "--local", chdir: dir) }
      raise "could not resolve the app bundle offline:\n#{output}" unless status.success?

      command = ["bundle", "exec", RbConfig.ruby, "app.rb"]
    end
    log_path = File.join(dir, "server.log")
    pid = unbundled { spawn(child_env, *command, chdir: dir, out: log_path, err: log_path, pgroup: true) }
    ShutdownProbe::Server.new(pid, port, dir, log_path).wait_until_serving!("/content-type/detected", timeout: 60)
  end

  # The suite runs under `bundle exec`; the child must not inherit its bundle.
  def unbundled(&block)
    defined?(Bundler) ? Bundler.with_unbundled_env(&block) : yield
  end

  # [status, every Content-Type value the server sent]
  def exchange(port, request)
    Net::HTTP.start("127.0.0.1", port, open_timeout: 5, read_timeout: 10) do |http|
      response = http.request(request)
      [response.code.to_i, response.get_fields("content-type") || []]
    end
  end

  def get(port, path) = exchange(port, Net::HTTP::Get.new(path))

  def post(port, path, byte_count)
    request = Net::HTTP::Post.new(path)
    request["Content-Type"] = "application/octet-stream"
    request.body = "x" * byte_count
    exchange(port, request)
  end

  { "the built-in server" => false, "Puma" => true }.each do |server_name, puma|
    context "on #{server_name}" do
      before(:all) { @server = boot(upload_limit, dotenv_health_path, puma: puma) }
      after(:all) { @server&.destroy! }

      it "is really served by #{server_name}" do
        if puma
          expect(@server.log).to include("Production server: puma")
        else
          # Not the banner: run! prints it before the server is chosen.
          expect(@server.log).not_to include("Production server: puma")
        end
      end

      it "header content type replaces the detected type" do
        expect(get(@server.port, "/content-type/header-with-bytes")).to eq([200, ["image/png"]])
      end

      it "a lowercase content type header is the same header" do
        expect(get(@server.port, "/content-type/lowercase-header")).to eq([200, ["image/png"]])
      end

      it "header content type survives a string body" do
        expect(get(@server.port, "/content-type/header-with-string")).to eq([200, ["text/csv"]])
      end

      it "an explicit content type argument wins over the header" do
        expect(get(@server.port, "/content-type/argument-after-header")).to eq([200, ["image/gif"]])
      end

      it "without a header the detected type is used" do
        status, content_types = get(@server.port, "/content-type/detected")
        expect(status).to eq(200)
        expect(content_types.size).to eq(1)
        expect(content_types.first.downcase).to start_with("text/")
      end

      it "max upload size from dotenv is enforced" do
        expect(post(@server.port, "/upload", upload_limit * 5).first).to eq(413)
      end

      it "a body under the dotenv limit is accepted" do
        expect(post(@server.port, "/upload", upload_limit / 2).first).to eq(200)
      end

      it "health path from dotenv is served" do
        expect(get(@server.port, dotenv_health_path).first).to eq(200)
      end
    end
  end

  describe "upload limit value" do
    around do |example|
      previous = ENV["TINA4_MAX_UPLOAD_SIZE"]
      example.run
    ensure
      previous.nil? ? ENV.delete("TINA4_MAX_UPLOAD_SIZE") : ENV["TINA4_MAX_UPLOAD_SIZE"] = previous
    end

    it "max upload size follows the environment" do
      ENV["TINA4_MAX_UPLOAD_SIZE"] = "2048"
      expect(Tina4::Request.max_upload_size).to eq(2048)
      ENV["TINA4_MAX_UPLOAD_SIZE"] = "4096"
      expect(Tina4::Request.max_upload_size).to eq(4096)
    end

    it "a bad max upload size falls back to the default" do
      fallbacks = ["ten megabytes", "-5", "0"].map do |bad|
        ENV["TINA4_MAX_UPLOAD_SIZE"] = bad
        Tina4::Request.max_upload_size
      end
      expect(fallbacks).to all(eq(10_485_760))
    end
  end
end
