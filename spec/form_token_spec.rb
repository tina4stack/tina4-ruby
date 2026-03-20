# frozen_string_literal: true

require "spec_helper"
require "json"
require "base64"

RSpec.describe "form_token template function" do
  let(:engine) { Tina4::Frond.new(template_dir: Dir.mktmpdir) }

  def decode_jwt_payload(token)
    parts = token.split(".")
    expect(parts.length).to eq(3), "Expected 3 dot-separated parts, got #{parts.length}"
    parts.each { |p| expect(p).not_to be_empty, "JWT segment must not be empty" }

    payload_b64 = parts[1]
    remainder = payload_b64.length % 4
    payload_b64 += "=" * (4 - remainder) if remainder != 0
    payload_json = Base64.decode64(payload_b64.tr("-_", "+/"))
    JSON.parse(payload_json)
  end

  def extract_token(html_output)
    expect(html_output).to include('<input type="hidden" name="formToken" value="'),
      "Expected hidden input element, got: #{html_output.inspect}"
    match = html_output.match(/value="([^"]+)"/)
    expect(match).not_to be_nil
    match[1]
  end

  context "as a global function" do
    it "renders a hidden input element" do
      output = engine.render_string("{{ form_token() }}")
      expect(output).to include('<input type="hidden" name="formToken" value="')
      expect(output.strip).to end_with('">')
    end

    it "does not HTML-escape the output" do
      output = engine.render_string("{{ form_token() }}")
      expect(output).not_to include("&lt;")
      expect(output).not_to include("&gt;")
    end

    it "produces a valid JWT token" do
      output = engine.render_string("{{ form_token() }}")
      token = extract_token(output)
      parts = token.split(".")
      expect(parts.length).to eq(3)
      payload = decode_jwt_payload(token)
      expect(payload["type"]).to eq("form")
    end

    it "has basic payload without context or ref" do
      output = engine.render_string("{{ form_token() }}")
      token = extract_token(output)
      payload = decode_jwt_payload(token)
      expect(payload["type"]).to eq("form")
      expect(payload).not_to have_key("context")
      expect(payload).not_to have_key("ref")
    end

    it "includes context when provided" do
      output = engine.render_string('{{ form_token("my_context") }}')
      token = extract_token(output)
      payload = decode_jwt_payload(token)
      expect(payload["type"]).to eq("form")
      expect(payload["context"]).to eq("my_context")
      expect(payload).not_to have_key("ref")
    end

    it "includes context and ref when pipe-separated" do
      output = engine.render_string('{{ form_token("checkout|order_123") }}')
      token = extract_token(output)
      payload = decode_jwt_payload(token)
      expect(payload["type"]).to eq("form")
      expect(payload["context"]).to eq("checkout")
      expect(payload["ref"]).to eq("order_123")
    end
  end

  context "as a filter" do
    it "renders a hidden input element" do
      output = engine.render_string('{{ "admin" | form_token }}')
      expect(output).to include('<input type="hidden" name="formToken" value="')
    end

    it "includes context from the filter value" do
      output = engine.render_string('{{ "admin" | form_token }}')
      token = extract_token(output)
      payload = decode_jwt_payload(token)
      expect(payload["context"]).to eq("admin")
    end

    it "handles pipe-separated descriptor in filter" do
      output = engine.render_string('{{ "checkout|order_123" | form_token }}')
      token = extract_token(output)
      payload = decode_jwt_payload(token)
      expect(payload["context"]).to eq("checkout")
      expect(payload["ref"]).to eq("order_123")
    end
  end
end
