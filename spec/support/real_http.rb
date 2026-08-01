# frozen_string_literal: true

require "stringio"

# ── Real Request / Response — the no-mock replacement for transport doubles ────
#
# `double("request")` / `double("response")` answer nothing, so any middleware
# that actually TOUCHED either argument would blow up. The test therefore
# silently constrains itself to middleware that ignore both, and proves nothing
# about the real request/response contract the pipeline depends on. A pipeline
# that passed the wrong objects, in the wrong order, or objects missing the
# accessors real middleware use, still passes.
#
# These build the GENUINE framework objects. A Rack env is a plain Hash of
# strings — exactly what a real server hands the app — and `rack.input` is a
# rewindable IO as the Rack SPEC defines it, so neither is a stand-in. The same
# shape is already used by crud_spec.rb:35-43, auth_check_spec.rb:46-59 and
# middleware_pipeline_characterisation_spec.rb:287.
module RealHttp
  # A real Tina4::Request built from a real Rack env.
  def build_request(method: "GET", path: "/test", query: "", host: "localhost",
                    body: "", content_type: nil, headers: {})
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => query,
      "HTTP_HOST" => host,
      "rack.input" => StringIO.new(body)
    }
    env["CONTENT_TYPE"] = content_type if content_type
    env["CONTENT_LENGTH"] = body.bytesize.to_s unless body.empty?
    # Real headers arrive as HTTP_* keys, upcased with dashes as underscores —
    # the same transformation a real Rack server performs.
    headers.each { |k, v| env["HTTP_#{k.to_s.upcase.tr('-', '_')}"] = v.to_s }
    Tina4::Request.new(env)
  end

  # A real Tina4::Response.
  def build_response
    Tina4::Response.new
  end
end

RSpec.configure do |config|
  config.include RealHttp
end
