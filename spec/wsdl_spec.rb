# frozen_string_literal: true

require "spec_helper"

# ── New class-based API (matches Python's WSDL) ─────────────────────────────

# Test subclass using wsdl_operation DSL
class TestCalculator < Tina4::WSDL
  wsdl_operation output: { Result: :int }
  def Add(a, b)
    { Result: a.to_i + b.to_i }
  end

  wsdl_operation output: { Greeting: :string }
  def Greet(name)
    { Greeting: "Hello #{name}" }
  end
end

# Subclass with lifecycle hooks
class HookedService < Tina4::WSDL
  attr_reader :hook_log

  def initialize(request = nil, service_url: "")
    super
    @hook_log = []
  end

  wsdl_operation output: { Value: :string }
  def Echo(msg)
    { Value: msg }
  end

  def on_request(request)
    @hook_log << :on_request
  end

  def on_result(result)
    @hook_log << :on_result
    result
  end
end

# Minimal request stub
RequestStub = Struct.new(:method, :body, :params, :url)

RSpec.describe Tina4::WSDL do
  describe "class-based wsdl_operation DSL" do
    it "discovers operations from decorated methods" do
      svc = TestCalculator.new
      expect(svc.class.wsdl_operations.keys).to contain_exactly("Add", "Greet")
    end

    it "records input parameter names" do
      ops = TestCalculator.wsdl_operations
      expect(ops["Add"][:input].keys).to eq(%i[a b])
    end

    it "records output schema" do
      ops = TestCalculator.wsdl_operations
      expect(ops["Add"][:output]).to eq({ Result: :int })
    end

    it "does not mark non-decorated methods as operations" do
      ops = TestCalculator.wsdl_operations
      expect(ops).not_to have_key("on_request")
      expect(ops).not_to have_key("on_result")
    end
  end

  describe "#handle — WSDL generation" do
    it "returns WSDL when request is nil" do
      svc = TestCalculator.new
      wsdl = svc.handle
      expect(wsdl).to include("<definitions")
      expect(wsdl).to include("TestCalculator")
    end

    it "returns WSDL on GET request" do
      req = RequestStub.new("GET", nil, {}, "/calculator")
      svc = TestCalculator.new(req)
      wsdl = svc.handle
      expect(wsdl).to include("<definitions")
    end

    it "returns WSDL when params contain wsdl key" do
      req = RequestStub.new("POST", "<soap/>", { "wsdl" => "" }, "/calculator")
      svc = TestCalculator.new(req)
      wsdl = svc.handle
      expect(wsdl).to include("<definitions")
    end

    it "returns WSDL when url ends with ?wsdl" do
      req = RequestStub.new("POST", "<soap/>", {}, "/calculator?wsdl")
      svc = TestCalculator.new(req)
      wsdl = svc.handle
      expect(wsdl).to include("<definitions")
    end
  end

  describe "#generate_wsdl" do
    let(:svc) { TestCalculator.new(nil, service_url: "http://localhost:7147/calculator") }
    let(:wsdl) { svc.generate_wsdl }

    it "starts with XML declaration" do
      expect(wsdl).to start_with('<?xml version="1.0" encoding="UTF-8"?>')
    end

    it "contains the service name" do
      expect(wsdl).to include('name="TestCalculator"')
    end

    it "sets targetNamespace as urn:ClassName" do
      expect(wsdl).to include('targetNamespace="urn:TestCalculator"')
    end

    it "contains types section" do
      expect(wsdl).to include("<types>")
      expect(wsdl).to include("</types>")
    end

    it "generates request elements for each operation" do
      expect(wsdl).to include('<xsd:element name="Add">')
      expect(wsdl).to include('<xsd:element name="Greet">')
    end

    it "generates response elements for each operation" do
      expect(wsdl).to include('<xsd:element name="AddResponse">')
      expect(wsdl).to include('<xsd:element name="GreetResponse">')
    end

    it "maps :int to xsd:int in output" do
      expect(wsdl).to include('type="xsd:int"')
    end

    it "maps :string to xsd:string in output" do
      expect(wsdl).to include('type="xsd:string"')
    end

    it "generates Input/Output messages" do
      expect(wsdl).to include('<message name="AddInput">')
      expect(wsdl).to include('<message name="AddOutput">')
    end

    it "generates portType" do
      expect(wsdl).to include('name="TestCalculatorPortType"')
    end

    it "generates binding with document style" do
      expect(wsdl).to include('name="TestCalculatorBinding"')
      expect(wsdl).to include('style="document"')
      expect(wsdl).to include('transport="http://schemas.xmlsoap.org/soap/http"')
    end

    it "generates soapAction for each operation" do
      expect(wsdl).to include('soapAction="urn:TestCalculator/Add"')
      expect(wsdl).to include('soapAction="urn:TestCalculator/Greet"')
    end

    it "generates service with soap:address" do
      expect(wsdl).to include('<service name="TestCalculator">')
      expect(wsdl).to include('location="http://localhost:7147/calculator"')
    end

    it "uses literal body encoding" do
      expect(wsdl).to include('use="literal"')
    end

    it "ends with </definitions>" do
      expect(wsdl.strip).to end_with("</definitions>")
    end
  end

  describe "#handle — SOAP request processing" do
    def soap_envelope(body_content)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>
            #{body_content}
          </soap:Body>
        </soap:Envelope>
      XML
    end

    it "invokes the Add operation and returns correct result" do
      xml = soap_envelope("<Add><a>3</a><b>5</b></Add>")
      req = RequestStub.new("POST", xml, {}, "/calculator")
      svc = TestCalculator.new(req)
      resp = svc.handle
      expect(resp).to include("<AddResponse>")
      expect(resp).to include("<Result>8</Result>")
    end

    it "invokes the Greet operation" do
      xml = soap_envelope("<Greet><name>Alice</name></Greet>")
      req = RequestStub.new("POST", xml, {}, "/calculator")
      svc = TestCalculator.new(req)
      resp = svc.handle
      expect(resp).to include("<GreetResponse>")
      expect(resp).to include("<Greeting>Hello Alice</Greeting>")
    end

    it "returns a SOAP envelope" do
      xml = soap_envelope("<Add><a>1</a><b>2</b></Add>")
      req = RequestStub.new("POST", xml, {}, "/calculator")
      resp = TestCalculator.new(req).handle
      expect(resp).to include("soap:Envelope")
      expect(resp).to include("soap:Body")
    end

    it "returns SOAP fault for unknown operation" do
      xml = soap_envelope("<Unknown><x>1</x></Unknown>")
      req = RequestStub.new("POST", xml, {}, "/calculator")
      resp = TestCalculator.new(req).handle
      expect(resp).to include("soap:Fault")
      expect(resp).to include("Unknown operation")
    end

    it "returns SOAP fault for malformed XML" do
      req = RequestStub.new("POST", "not xml at all <<<", {}, "/calculator")
      resp = TestCalculator.new(req).handle
      expect(resp).to include("soap:Fault")
      expect(resp).to include("Malformed XML")
    end

    it "returns SOAP fault for missing Body" do
      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Header/></soap:Envelope>'
      req = RequestStub.new("POST", xml, {}, "/calculator")
      resp = TestCalculator.new(req).handle
      expect(resp).to include("soap:Fault")
      expect(resp).to include("Missing SOAP Body")
    end

    it "returns SOAP fault for empty Body" do
      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body></soap:Body></soap:Envelope>'
      req = RequestStub.new("POST", xml, {}, "/calculator")
      resp = TestCalculator.new(req).handle
      expect(resp).to include("soap:Fault")
      expect(resp).to include("Empty SOAP Body")
    end

    it "returns SOAP fault when handler raises" do
      klass = Class.new(Tina4::WSDL) do
        wsdl_operation output: {}
        def Boom
          raise "kaboom"
        end
      end
      xml = soap_envelope("<Boom/>")
      req = RequestStub.new("POST", xml, {}, "/test")
      resp = klass.new(req).handle
      expect(resp).to include("soap:Fault")
      expect(resp).to include("kaboom")
    end

    it "XML-escapes response values" do
      klass = Class.new(Tina4::WSDL) do
        wsdl_operation output: { Msg: :string }
        def Escape
          { Msg: "<script>alert('xss')</script>" }
        end
      end
      xml = soap_envelope("<Escape/>")
      req = RequestStub.new("POST", xml, {}, "/test")
      resp = klass.new(req).handle
      expect(resp).not_to include("<script>")
      expect(resp).to include("&lt;script&gt;")
    end

    it "handles nil values with xsi:nil" do
      klass = Class.new(Tina4::WSDL) do
        wsdl_operation output: { Value: :string }
        def NilOp
          { Value: nil }
        end
      end
      xml = soap_envelope("<NilOp/>")
      req = RequestStub.new("POST", xml, {}, "/test")
      resp = klass.new(req).handle
      expect(resp).to include('xsi:nil="true"')
    end

    it "handles array values as repeated elements" do
      klass = Class.new(Tina4::WSDL) do
        wsdl_operation output: { Item: :string }
        def ListOp
          { Item: %w[one two three] }
        end
      end
      xml = soap_envelope("<ListOp/>")
      req = RequestStub.new("POST", xml, {}, "/test")
      resp = klass.new(req).handle
      expect(resp).to include("<Item>one</Item>")
      expect(resp).to include("<Item>two</Item>")
      expect(resp).to include("<Item>three</Item>")
    end
  end

  describe "lifecycle hooks" do
    it "calls on_request and on_result" do
      xml = <<~XML
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body><Echo><msg>test</msg></Echo></soap:Body>
        </soap:Envelope>
      XML
      req = RequestStub.new("POST", xml, {}, "/test")
      svc = HookedService.new(req)
      svc.handle
      expect(svc.hook_log).to eq(%i[on_request on_result])
    end
  end

  describe "type mapping" do
    {
      int:      "xsd:int",
      integer:  "xsd:int",
      string:   "xsd:string",
      float:    "xsd:double",
      double:   "xsd:double",
      boolean:  "xsd:boolean",
      bool:     "xsd:boolean",
      date:     "xsd:date",
      datetime: "xsd:dateTime",
      base64:   "xsd:base64Binary",
      Integer   => "xsd:int",
      String    => "xsd:string",
      Float     => "xsd:double"
    }.each do |ruby_type, expected_xsd|
      it "maps #{ruby_type.inspect} to #{expected_xsd}" do
        klass = Class.new(Tina4::WSDL) do
          wsdl_operation output: { Val: ruby_type }
          def TypeOp
            { Val: "x" }
          end
        end
        wsdl = klass.new.generate_wsdl
        expect(wsdl).to include("type=\"#{expected_xsd}\"")
      end
    end

    it "maps unknown types to xsd:string" do
      klass = Class.new(Tina4::WSDL) do
        wsdl_operation output: { Val: :custom_thing }
        def TypeOp
          { Val: "x" }
        end
      end
      wsdl = klass.new.generate_wsdl
      # The output element for Val should be xsd:string
      expect(wsdl).to include('type="xsd:string"')
    end
  end

  describe "type coercion in SOAP requests" do
    def soap_envelope(body)
      "<soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\"><soap:Body>#{body}</soap:Body></soap:Envelope>"
    end

    it "converts integer parameters" do
      xml = soap_envelope("<Add><a>10</a><b>20</b></Add>")
      req = RequestStub.new("POST", xml, {}, "/calc")
      resp = TestCalculator.new(req).handle
      expect(resp).to include("<Result>30</Result>")
    end
  end
end

# ── Legacy Service API (backward compatibility) ──────────────────────────────

RSpec.describe Tina4::WSDL::Service do
  let(:service) { described_class.new(name: "Calculator", namespace: "http://test.com/wsdl") }

  describe "#initialize" do
    it "sets the service name" do
      expect(service.name).to eq("Calculator")
    end

    it "sets the namespace" do
      expect(service.namespace).to eq("http://test.com/wsdl")
    end

    it "starts with no operations" do
      expect(service.operations).to be_empty
    end

    it "uses default namespace when not provided" do
      svc = described_class.new(name: "MyService")
      expect(svc.namespace).to eq("http://tina4.com/wsdl")
    end
  end

  describe "#add_operation" do
    it "adds an operation" do
      service.add_operation("Add", input_params: { a: "int", b: "int" },
                            output_params: { result: "int" }) { |_params| 0 }
      expect(service.operations).to have_key("Add")
    end

    it "stores input params" do
      service.add_operation("Add", input_params: { a: "int", b: "int" },
                            output_params: {}) { |_| nil }
      expect(service.operations["Add"][:input]).to eq({ a: "int", b: "int" })
    end

    it "stores output params" do
      service.add_operation("Add", input_params: {},
                            output_params: { result: "int" }) { |_| nil }
      expect(service.operations["Add"][:output]).to eq({ result: "int" })
    end

    it "stores the handler block" do
      service.add_operation("Add", input_params: {}, output_params: {}) { |_| 42 }
      expect(service.operations["Add"][:handler]).to be_a(Proc)
    end

    it "converts symbol operation names to strings" do
      service.add_operation(:Subtract, input_params: {}, output_params: {}) { |_| nil }
      expect(service.operations).to have_key("Subtract")
    end

    it "supports multiple operations" do
      service.add_operation("Add", input_params: {}, output_params: {}) { |_| nil }
      service.add_operation("Multiply", input_params: {}, output_params: {}) { |_| nil }
      expect(service.operations.keys).to eq(%w[Add Multiply])
    end
  end

  describe "#generate_wsdl" do
    before do
      service.add_operation("Add",
                            input_params: { a: "integer", b: "integer" },
                            output_params: { result: "integer" }) { |params| { result: params["a"].to_i + params["b"].to_i } }
      service.add_operation("Greet",
                            input_params: { name: "string" },
                            output_params: { greeting: "string" }) { |params| { greeting: "Hello #{params['name']}" } }
    end

    let(:wsdl) { service.generate_wsdl("http://localhost:3000/soap") }

    it "returns a string" do
      expect(wsdl).to be_a(String)
    end

    it "starts with XML declaration" do
      expect(wsdl).to start_with('<?xml version="1.0" encoding="UTF-8"?>')
    end

    it "contains definitions element" do
      expect(wsdl).to include("<definitions")
    end

    it "contains service name" do
      expect(wsdl).to include('name="Calculator"')
    end

    it "contains target namespace" do
      expect(wsdl).to include('targetNamespace="http://test.com/wsdl"')
    end

    it "contains types section" do
      expect(wsdl).to include("<types>")
      expect(wsdl).to include("</types>")
    end

    it "contains xsd:schema" do
      expect(wsdl).to include("<xsd:schema")
    end

    it "contains Add operation" do
      expect(wsdl).to include('name="Add"')
    end

    it "contains Greet operation" do
      expect(wsdl).to include('name="Greet"')
    end

    it "contains AddRequest element" do
      expect(wsdl).to include('element="tns:AddRequest"')
    end

    it "contains AddResponse element" do
      expect(wsdl).to include('element="tns:AddResponse"')
    end

    it "contains GreetRequest message" do
      expect(wsdl).to include('name="GreetRequest"')
    end

    it "contains GreetResponse message" do
      expect(wsdl).to include('name="GreetResponse"')
    end

    it "contains portType" do
      expect(wsdl).to include('name="CalculatorPortType"')
    end

    it "contains binding" do
      expect(wsdl).to include('name="CalculatorBinding"')
    end

    it "uses document style binding" do
      expect(wsdl).to include('style="document"')
    end

    it "contains SOAP transport" do
      expect(wsdl).to include('transport="http://schemas.xmlsoap.org/soap/http"')
    end

    it "contains soapAction for operations" do
      expect(wsdl).to include("soapAction=\"http://test.com/wsdl/Add\"")
      expect(wsdl).to include("soapAction=\"http://test.com/wsdl/Greet\"")
    end

    it "contains service element" do
      expect(wsdl).to include("<service")
    end

    it "contains port element" do
      expect(wsdl).to include('name="CalculatorPort"')
    end

    it "contains soap:address with endpoint URL" do
      expect(wsdl).to include('location="http://localhost:3000/soap"')
    end

    it "maps integer type to xsd:int" do
      expect(wsdl).to include('type="xsd:int"')
    end

    it "maps string type to xsd:string" do
      expect(wsdl).to include('type="xsd:string"')
    end

    it "contains literal body use" do
      expect(wsdl).to include('use="literal"')
    end

    it "ends with </definitions>" do
      expect(wsdl.strip).to end_with("</definitions>")
    end
  end

  describe "type mapping" do
    it "maps float to xsd:double" do
      svc = described_class.new(name: "Test")
      svc.add_operation("Op", input_params: { val: "float" }, output_params: {}) { |_| nil }
      wsdl = svc.generate_wsdl("http://localhost/test")
      expect(wsdl).to include('type="xsd:double"')
    end

    it "maps boolean to xsd:boolean" do
      svc = described_class.new(name: "Test")
      svc.add_operation("Op", input_params: { flag: "boolean" }, output_params: {}) { |_| nil }
      wsdl = svc.generate_wsdl("http://localhost/test")
      expect(wsdl).to include('type="xsd:boolean"')
    end

    it "maps date to xsd:date" do
      svc = described_class.new(name: "Test")
      svc.add_operation("Op", input_params: { d: "date" }, output_params: {}) { |_| nil }
      wsdl = svc.generate_wsdl("http://localhost/test")
      expect(wsdl).to include('type="xsd:date"')
    end

    it "maps datetime to xsd:dateTime" do
      svc = described_class.new(name: "Test")
      svc.add_operation("Op", input_params: { dt: "datetime" }, output_params: {}) { |_| nil }
      wsdl = svc.generate_wsdl("http://localhost/test")
      expect(wsdl).to include('type="xsd:dateTime"')
    end

    it "maps unknown types to xsd:string" do
      svc = described_class.new(name: "Test")
      svc.add_operation("Op", input_params: { x: "custom" }, output_params: {}) { |_| nil }
      wsdl = svc.generate_wsdl("http://localhost/test")
      expect(wsdl).to include('type="xsd:string"')
    end
  end

  describe "#handle_soap_request" do
    before do
      service.add_operation("Add",
                            input_params: { a: "integer", b: "integer" },
                            output_params: { result: "integer" }) do |params|
        { result: params["a"].to_i + params["b"].to_i }
      end

      service.add_operation("Greet",
                            input_params: { name: "string" },
                            output_params: { greeting: "string" }) do |params|
        { greeting: "Hello #{params['name']}" }
      end
    end

    it "handles a valid Add request" do
      xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>
            <Add><a>3</a><b>5</b></Add>
          </soap:Body>
        </soap:Envelope>
      XML

      response = service.handle_soap_request(xml)
      expect(response).to include("AddResponse")
      expect(response).to include("<result>8</result>")
    end

    it "handles a valid Greet request" do
      xml = <<~XML
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>
            <Greet><name>Alice</name></Greet>
          </soap:Body>
        </soap:Envelope>
      XML

      response = service.handle_soap_request(xml)
      expect(response).to include("GreetResponse")
      expect(response).to include("<greeting>Hello Alice</greeting>")
    end

    it "returns SOAP envelope in response" do
      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><Add><a>1</a><b>2</b></Add></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("soap:Envelope")
      expect(response).to include("soap:Body")
    end

    it "returns XML declaration in response" do
      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><Add><a>1</a><b>2</b></Add></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to start_with('<?xml version="1.0" encoding="UTF-8"?>')
    end

    it "returns SOAP fault for unknown operation" do
      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><Unknown><x>1</x></Unknown></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("soap:Fault")
      expect(response).to include("Unknown operation")
    end

    it "returns SOAP fault with faultcode" do
      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><Unknown><x>1</x></Unknown></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("faultcode")
      expect(response).to include("soap:Server")
    end

    it "returns SOAP fault with faultstring" do
      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><Unknown><x>1</x></Unknown></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("faultstring")
    end

    it "handles handler that returns non-hash result" do
      svc = described_class.new(name: "Simple")
      svc.add_operation("Echo", input_params: { msg: "string" }, output_params: {}) do |params|
        params["msg"]
      end

      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><Echo><msg>hello</msg></Echo></soap:Body></soap:Envelope>'
      response = svc.handle_soap_request(xml)
      expect(response).to include("<result>hello</result>")
    end

    it "handles handler exception as SOAP fault" do
      svc = described_class.new(name: "Broken")
      svc.add_operation("Fail", input_params: {}, output_params: {}) do |_|
        raise "Something went wrong"
      end

      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><Fail></Fail></soap:Body></soap:Envelope>'
      response = svc.handle_soap_request(xml)
      expect(response).to include("soap:Fault")
      expect(response).to include("Something went wrong")
    end

    it "extracts multiple params from XML" do
      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><Add><a>10</a><b>20</b></Add></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("<result>30</result>")
    end

    it "includes namespace in response" do
      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><Add><a>1</a><b>1</b></Add></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("tns:AddResponse")
      expect(response).to include(service.namespace)
    end

    it "XML-escapes response values" do
      svc = described_class.new(name: "Escaper")
      svc.add_operation("XSS", input_params: {}, output_params: {}) do |_|
        { msg: "<script>alert('x')</script>" }
      end
      xml = '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><XSS/></soap:Body></soap:Envelope>'
      response = svc.handle_soap_request(xml)
      expect(response).not_to include("<script>")
      expect(response).to include("&lt;script&gt;")
    end
  end
end
