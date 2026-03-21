# frozen_string_literal: true

require_relative "../lib/tina4/error_overlay"

RSpec.describe Tina4::ErrorOverlay do
  def make_exception
    raise "something broke"
  rescue RuntimeError => e
    e
  end

  describe ".render" do
    it "returns an HTML string" do
      html = described_class.render(make_exception)
      expect(html).to start_with("<!DOCTYPE html>")
    end

    it "contains the exception type" do
      html = described_class.render(make_exception)
      expect(html).to include("RuntimeError")
    end

    it "contains the exception message" do
      html = described_class.render(make_exception)
      expect(html).to include("something broke")
    end

    it "contains the file path" do
      html = described_class.render(make_exception)
      expect(html).to include("error_overlay_spec.rb")
    end

    it "contains source code" do
      html = described_class.render(make_exception)
      expect(html).to include("something broke")
    end

    it "contains the error line marker" do
      html = described_class.render(make_exception)
      expect(html).to include("&#x25b6;")
    end

    it "includes request details when provided" do
      request = {
        "REQUEST_METHOD" => "GET",
        "REQUEST_URI" => "/api/users",
        "HTTP_HOST" => "localhost"
      }
      html = described_class.render(make_exception, request: request)
      expect(html).to include("GET")
      expect(html).to include("/api/users")
      expect(html).to include("localhost")
      expect(html).to include("Request Details")
    end

    it "omits request section when no request given" do
      html = described_class.render(make_exception)
      # Check that the collapsible summary for request is not rendered
      expect(html).not_to include('user-select:none;">Request Details</summary>')
    end

    it "contains the environment section" do
      html = described_class.render(make_exception)
      expect(html).to include("Environment")
      expect(html).to include("Tina4 Ruby")
      expect(html).to include("Ruby")
    end

    it "contains the debug mode footer" do
      html = described_class.render(make_exception)
      expect(html).to include("TINA4_DEBUG_LEVEL")
    end

    it "escapes HTML in the exception message" do
      begin
        raise "<script>alert('xss')</script>"
      rescue RuntimeError => e
        html = described_class.render(e)
        expect(html).not_to include("<script>")
        expect(html).to include("&lt;script&gt;")
      end
    end

    it "has the stack trace section open by default" do
      html = described_class.render(make_exception)
      expect(html).to include("Stack Trace")
      expect(html).to include("<details")
      expect(html).to include("open")
    end
  end

  describe ".render_production" do
    it "returns an HTML string" do
      html = described_class.render_production
      expect(html).to start_with("<!DOCTYPE html>")
    end

    it "contains the status code" do
      html = described_class.render_production(status_code: 404, message: "Not Found")
      expect(html).to include("404")
      expect(html).to include("Not Found")
    end

    it "does not contain stack trace" do
      html = described_class.render_production
      expect(html).not_to include("Stack Trace")
    end

    it "defaults to 500" do
      html = described_class.render_production
      expect(html).to include("500")
      expect(html).to include("Internal Server Error")
    end
  end

  describe ".debug_mode?" do
    after { ENV.delete("TINA4_DEBUG") }

    it "returns true for ALL" do
      ENV["TINA4_DEBUG"] = "true"
      expect(described_class.debug_mode?).to be true
    end

    it "returns true for DEBUG" do
      ENV["TINA4_DEBUG"] = "1"
      expect(described_class.debug_mode?).to be true
    end

    it "returns false for WARNING" do
      ENV["TINA4_DEBUG"] = "false"
      expect(described_class.debug_mode?).to be false
    end

    it "returns false when not set" do
      ENV.delete("TINA4_DEBUG")
      expect(described_class.debug_mode?).to be false
    end
  end
end
