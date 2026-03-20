# frozen_string_literal: true

require "spec_helper"

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
      xml = '<soap:Envelope><soap:Body><Add><a>1</a><b>2</b></Add></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("soap:Envelope")
      expect(response).to include("soap:Body")
    end

    it "returns XML declaration in response" do
      xml = '<soap:Envelope><soap:Body><Add><a>1</a><b>2</b></Add></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to start_with('<?xml version="1.0" encoding="UTF-8"?>')
    end

    it "returns SOAP fault for unknown operation" do
      xml = '<soap:Envelope><soap:Body><Unknown><x>1</x></Unknown></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("soap:Fault")
      expect(response).to include("Unknown operation")
    end

    it "returns SOAP fault with faultcode" do
      xml = '<soap:Envelope><soap:Body><Unknown><x>1</x></Unknown></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("faultcode")
      expect(response).to include("soap:Server")
    end

    it "returns SOAP fault with faultstring" do
      xml = '<soap:Envelope><soap:Body><Unknown><x>1</x></Unknown></soap:Body></soap:Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("faultstring")
    end

    it "handles handler that returns non-hash result" do
      svc = described_class.new(name: "Simple")
      svc.add_operation("Echo", input_params: { msg: "string" }, output_params: {}) do |params|
        params["msg"]
      end

      xml = '<Envelope><Body><Echo><msg>hello</msg></Echo></Body></Envelope>'
      response = svc.handle_soap_request(xml)
      expect(response).to include("<result>hello</result>")
    end

    it "handles handler exception as SOAP fault" do
      svc = described_class.new(name: "Broken")
      svc.add_operation("Fail", input_params: {}, output_params: {}) do |_|
        raise "Something went wrong"
      end

      xml = '<Envelope><Body><Fail></Fail></Body></Envelope>'
      response = svc.handle_soap_request(xml)
      expect(response).to include("soap:Fault")
      expect(response).to include("Something went wrong")
    end

    it "extracts multiple params from XML" do
      xml = '<Envelope><Body><Add><a>10</a><b>20</b></Add></Body></Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("<result>30</result>")
    end

    it "includes namespace in response" do
      xml = '<Envelope><Body><Add><a>1</a><b>1</b></Add></Body></Envelope>'
      response = service.handle_soap_request(xml)
      expect(response).to include("tns:AddResponse")
      expect(response).to include(service.namespace)
    end
  end
end
