# frozen_string_literal: true

require "spec_helper"
require "stringio"

# The shared SOAP body encoding rule (all four frameworks): refuse, BEFORE any
# parse, with the Client "Malformed XML" fault:
#   * any byte order mark, the UTF-8 one included
#   * bytes that are not valid UTF-8
#   * any NUL byte
#   * an XML declaration whose encoding is anything but "UTF-8" (any case)
#
# MEASURED at v3 after tina4-ruby#49 (its parser already refused UTF-16/32 BOMs,
# NUL bytes and invalid UTF-8): a UTF-8 BOM was skipped and the body served, and
# an ASCII body declaring encoding="ISO-8859-1" was served as if it were UTF-8.
# The WSDL::Service path answered every refusal as "Internal server error",
# because its parse error fell into the operation's catch-all.
#
# The body travels through a REAL Tina4::Request built from a Rack env, exactly
# as the server hands it over; nothing is stubbed and no server is booted.
RSpec.describe "WSDL SOAP body encoding rule" do
  def envelope(inner, declaration: %(<?xml version="1.0" encoding="UTF-8"?>))
    "#{declaration}<soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\" " \
      "xmlns:t=\"urn:tina4:parity\"><soap:Body>#{inner}</soap:Body></soap:Envelope>"
  end

  def doctype_echo(declaration)
    %(#{declaration}<!DOCTYPE soap:Envelope [<!ENTITY e "EXPANDED">]>) +
      envelope("<t:Echo><t:text>&e;</t:text></t:Echo>", declaration: "")
  end

  def real_request(raw)
    bytes = raw.b
    Tina4::Request.new(
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "/soap", "QUERY_STRING" => "",
      "CONTENT_TYPE" => "text/xml; charset=utf-8", "CONTENT_LENGTH" => bytes.bytesize.to_s,
      "HTTP_HOST" => "localhost", "SERVER_PORT" => "80", "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(bytes)
    )
  end

  let(:calls) { [] }

  let(:service_class) do
    recorded = calls
    Class.new(Tina4::WSDL) do
      wsdl_operation output: { Result: :string }
      define_method(:Echo) do |text|
        recorded << text
        { Result: text }
      end
    end
  end

  let(:plain_service) do
    recorded = calls
    Tina4::WSDL::Service.new(name: "Parity").tap do |service|
      service.add_operation("Echo", input_params: { text: :string }, output_params: { Result: :string }) do |params|
        recorded << params["text"]
        { Result: params["text"] }
      end
    end
  end

  utf16_doctype = lambda do |bom|
    xml = %(<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE soap:Envelope [<!ENTITY e "EXPANDED">]>) +
          "<soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:t=\"urn:tina4:parity\">" \
          "<soap:Body><t:Echo><t:text>&e;</t:text></t:Echo></soap:Body></soap:Envelope>"
    (bom ? "\xFF\xFE".b : "".b) + xml.encode("UTF-16LE").b
  end

  refused = {
    "row 10: UTF-16LE with a BOM and a DOCTYPE" => -> { utf16_doctype.call(true) },
    "row 11: UTF-7 declared, DOCTYPE written in UTF-7" => lambda {
      %(<?xml version="1.0" encoding="UTF-7"?>+ADwAIQ-DOCTYPE soap:Envelope +AFsAPAAh-ENTITY e ) +
        %(+ACI-EXPANDED+ACIAPgBdAD4-<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" ) +
        %(xmlns:t="urn:tina4:parity"><soap:Body><t:Echo><t:text>&e;</t:text></t:Echo></soap:Body></soap:Envelope>)
    },
    "row 12: UTF-16LE without a BOM" => -> { utf16_doctype.call(false) },
    "an ASCII body declaring ISO-8859-1" => lambda {
      envelope("<t:Echo><t:text>hello</t:text></t:Echo>",
               declaration: %(<?xml version="1.0" encoding="ISO-8859-1"?>))
    },
    "a UTF-8 BOM in front of a valid UTF-8 body" => lambda {
      "\xEF\xBB\xBF".b + envelope("<t:Echo><t:text>hello</t:text></t:Echo>").b
    },
    "bytes that are not valid UTF-8" => -> { envelope("<t:Echo><t:text>caf\xE9</t:text></t:Echo>".b).b },
    "a NUL byte inside an otherwise UTF-8 body" => -> { envelope("<t:Echo><t:text>a\u0000b</t:text></t:Echo>") }
  }

  refused.each do |label, body|
    it "Tina4::WSDL refuses #{label} with the Client 'Malformed XML' fault and never runs the operation" do
      response = service_class.new(real_request(instance_exec(&body))).handle
      expect(response).to include("<faultcode>Client</faultcode>")
      expect(response).to include("<faultstring>Malformed XML</faultstring>")
      expect(response).not_to include("EXPANDED")
      expect(calls).to be_empty
    end

    it "Tina4::WSDL::Service refuses #{label} as 'Malformed XML' and never runs the handler" do
      response = plain_service.handle_soap_request(instance_exec(&body))
      expect(response).to include("<faultstring>Malformed XML</faultstring>")
      expect(response).not_to include("EXPANDED")
      expect(calls).to be_empty
    end
  end

  # The DOCTYPE refusal still answers a valid UTF-8 body (row 09).
  it "still answers a UTF-8 DOCTYPE with the DOCTYPE fault" do
    response = service_class.new(real_request(doctype_echo(%(<?xml version="1.0"?>)))).handle
    expect(response).to include("DOCTYPE declarations are not allowed in SOAP messages")
    expect(calls).to be_empty
  end

  # Positive: UTF-8 in any case, or no declaration at all, is served.
  [%(<?xml version="1.0" encoding="UTF-8"?>), %(<?xml version="1.0" encoding='utf-8'?>),
   %(<?xml version="1.0"?>), ""].each do |declaration|
    it "serves a UTF-8 body with declaration #{declaration.inspect}" do
      body = envelope("<t:Echo><t:text>café</t:text></t:Echo>", declaration: declaration)
      expect(service_class.new(real_request(body)).handle).to include("<Result>café</Result>")
      expect(plain_service.handle_soap_request(body)).to include("café")
      expect(calls).to eq(["café", "café"])
    end
  end
end
