# frozen_string_literal: true

require "rexml/document"

module Tina4
  # SOAP 1.1 / WSDL server — zero-dependency, mirrors tina4-python's wsdl module.
  #
  # Usage (class-based):
  #
  #   class Calculator < Tina4::WSDL
  #     wsdl_operation output: { Result: :int }
  #     def add(a, b)
  #       { Result: a.to_i + b.to_i }
  #     end
  #   end
  #
  #   # In a route handler:
  #   service = Calculator.new(request)
  #   response.call(service.handle)
  #
  # Supported:
  #   - WSDL 1.1 generation from Ruby type declarations
  #   - SOAP 1.1 request/response handling via REXML
  #   - Lifecycle hooks (on_request, on_result)
  #   - Auto type mapping (Integer -> int, String -> string, Float -> double, etc.)
  #   - XML escaping on all response values
  #   - SOAP fault responses on errors
  #
  class WSDL
    NS_SOAP     = "http://schemas.xmlsoap.org/wsdl/soap/"
    NS_WSDL     = "http://schemas.xmlsoap.org/wsdl/"
    NS_XSD      = "http://www.w3.org/2001/XMLSchema"
    NS_SOAP_ENV = "http://schemas.xmlsoap.org/soap/envelope/"

    RUBY_TO_XSD = {
      :int        => "xsd:int",
      :integer    => "xsd:int",
      :string     => "xsd:string",
      :float      => "xsd:double",
      :double     => "xsd:double",
      :boolean    => "xsd:boolean",
      :bool       => "xsd:boolean",
      :date       => "xsd:date",
      :datetime   => "xsd:dateTime",
      :base64     => "xsd:base64Binary",
      Integer     => "xsd:int",
      String      => "xsd:string",
      Float       => "xsd:double",
      TrueClass   => "xsd:boolean",
      FalseClass  => "xsd:boolean"
    }.freeze

    # ── Class-level DSL ──────────────────────────────────────────────────

    class << self
      # Registry of operations declared via wsdl_operation + def.
      # Each entry: { input: { name => type, ... }, output: { name => type, ... } }
      def wsdl_operations
        @wsdl_operations ||= {}
      end

      # Pending output hash waiting for the next method definition.
      def pending_wsdl_output
        @pending_wsdl_output
      end

      # Mark the next defined method as a WSDL operation.
      #
      #   wsdl_operation output: { Result: :int }
      #   def add(a, b) ...
      #
      # Input parameters are inferred from the method signature.
      # The +output+ hash maps response element names to XSD type symbols.
      def wsdl_operation(output: {})
        @pending_wsdl_output = output
      end

      # Hook into method definition to capture the pending operation.
      def method_added(method_name)
        super
        return unless @pending_wsdl_output

        output = @pending_wsdl_output
        @pending_wsdl_output = nil

        # Infer input parameter names from the method signature.
        params = instance_method(method_name).parameters
        input = {}
        params.each do |_kind, name|
          next if name.nil?
          input[name] = :string # default; callers can rely on type coercion
        end

        wsdl_operations[method_name.to_s] = { input: input, output: output }
      end

      # Ensure subclasses get their own copy of the operations registry.
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@wsdl_operations, wsdl_operations.dup)
      end
    end

    # ── Instance ─────────────────────────────────────────────────────────

    attr_reader :request, :service_url

    def initialize(request = nil, service_url: "")
      @request     = request
      @service_url = service_url.empty? ? infer_url : service_url
      @operations  = discover_operations
    end

    # Main entry point. Returns WSDL XML on GET/?wsdl, or processes a SOAP
    # request on POST.
    def handle
      return generate_wsdl if @request.nil?

      method = if @request.respond_to?(:method)
                 @request.method.to_s.upcase
               elsif @request.respond_to?(:body) && @request.body && !@request.body.to_s.empty?
                 "POST"
               else
                 "GET"
               end

      params = (@request.respond_to?(:params) ? @request.params : nil) || {}
      url    = (@request.respond_to?(:url) ? @request.url : nil) || ""

      if method == "GET" || params.key?("wsdl") || params.key?(:wsdl) || url.end_with?("?wsdl")
        return generate_wsdl
      end

      body = if @request.respond_to?(:body)
               @request.body.is_a?(String) ? @request.body : @request.body.to_s
             else
               ""
             end

      process_soap(body)
    end

    # ── Lifecycle hooks (override in subclass) ───────────────────────────

    # Called before operation invocation. Override to validate/log.
    def on_request(request)
      # no-op
    end

    # Called after operation returns. Override to transform/audit.
    # Must return the (possibly modified) result.
    def on_result(result)
      result
    end

    # ── WSDL generation ──────────────────────────────────────────────────

    def generate_wsdl
      service_name = self.class.name ? self.class.name.split("::").last : "AnonymousService"
      tns = "urn:#{service_name}"

      parts = []
      parts << '<?xml version="1.0" encoding="UTF-8"?>'
      parts << "<definitions name=\"#{service_name}\""
      parts << "  targetNamespace=\"#{tns}\""
      parts << "  xmlns:tns=\"#{tns}\""
      parts << "  xmlns:soap=\"#{NS_SOAP}\""
      parts << "  xmlns:xsd=\"#{NS_XSD}\""
      parts << "  xmlns=\"#{NS_WSDL}\">"
      parts << ""

      # Types
      parts << "  <types>"
      parts << "    <xsd:schema targetNamespace=\"#{tns}\">"

      @operations.each do |op_name, meta|
        # Request element
        parts << "      <xsd:element name=\"#{op_name}\">"
        parts << "        <xsd:complexType>"
        parts << "          <xsd:sequence>"
        meta[:input].each do |pname, ptype|
          xsd = xsd_type(ptype)
          parts << "            <xsd:element name=\"#{pname}\" type=\"#{xsd}\"/>"
        end
        parts << "          </xsd:sequence>"
        parts << "        </xsd:complexType>"
        parts << "      </xsd:element>"

        # Response element
        parts << "      <xsd:element name=\"#{op_name}Response\">"
        parts << "        <xsd:complexType>"
        parts << "          <xsd:sequence>"
        meta[:output].each do |rname, rtype|
          xsd = xsd_type(rtype)
          parts << "            <xsd:element name=\"#{rname}\" type=\"#{xsd}\"/>"
        end
        parts << "          </xsd:sequence>"
        parts << "        </xsd:complexType>"
        parts << "      </xsd:element>"
      end

      parts << "    </xsd:schema>"
      parts << "  </types>"
      parts << ""

      # Messages
      @operations.each_key do |op_name|
        parts << "  <message name=\"#{op_name}Input\">"
        parts << "    <part name=\"parameters\" element=\"tns:#{op_name}\"/>"
        parts << "  </message>"
        parts << "  <message name=\"#{op_name}Output\">"
        parts << "    <part name=\"parameters\" element=\"tns:#{op_name}Response\"/>"
        parts << "  </message>"
      end
      parts << ""

      # PortType
      parts << "  <portType name=\"#{service_name}PortType\">"
      @operations.each_key do |op_name|
        parts << "    <operation name=\"#{op_name}\">"
        parts << "      <input message=\"tns:#{op_name}Input\"/>"
        parts << "      <output message=\"tns:#{op_name}Output\"/>"
        parts << "    </operation>"
      end
      parts << "  </portType>"
      parts << ""

      # Binding
      parts << "  <binding name=\"#{service_name}Binding\" type=\"tns:#{service_name}PortType\">"
      parts << "    <soap:binding style=\"document\" transport=\"http://schemas.xmlsoap.org/soap/http\"/>"
      @operations.each_key do |op_name|
        parts << "    <operation name=\"#{op_name}\">"
        parts << "      <soap:operation soapAction=\"#{tns}/#{op_name}\"/>"
        parts << '      <input><soap:body use="literal"/></input>'
        parts << '      <output><soap:body use="literal"/></output>'
        parts << "    </operation>"
      end
      parts << "  </binding>"
      parts << ""

      # Service
      parts << "  <service name=\"#{service_name}\">"
      parts << "    <port name=\"#{service_name}Port\" binding=\"tns:#{service_name}Binding\">"
      parts << "      <soap:address location=\"#{@service_url}\"/>"
      parts << "    </port>"
      parts << "  </service>"

      parts << "</definitions>"
      parts.join("\n")
    end

    private

    # ── Auto-discovery ───────────────────────────────────────────────────

    def discover_operations
      self.class.wsdl_operations.dup
    end

    def infer_url
      return @request.url if @request && @request.respond_to?(:url)
      "/"
    end

    # ── SOAP request processing ──────────────────────────────────────────

    def process_soap(xml_body)
      on_request(@request)

      begin
        doc = REXML::Document.new(xml_body)
      rescue REXML::ParseException
        return soap_fault("Client", "Malformed XML")
      end

      # Find the SOAP Body element (namespace-agnostic)
      body_el = find_child(doc.root, "Body")
      return soap_fault("Client", "Missing SOAP Body") unless body_el

      # First child of Body is the operation element
      op_el = body_el.elements.first
      return soap_fault("Client", "Empty SOAP Body") unless op_el

      op_name = local_name(op_el)

      unless @operations.key?(op_name)
        return soap_fault("Client", "Unknown operation: #{op_name}")
      end

      meta = @operations[op_name]

      # Extract parameters from the operation element
      params = {}
      meta[:input].each do |param_name, param_type|
        child = find_child(op_el, param_name.to_s)
        if child
          value = child.text || ""
          params[param_name.to_s] = convert_value(value, param_type)
        end
      end

      begin
        result = send(op_name.to_sym, *meta[:input].keys.map { |k| params[k.to_s] })
        result = on_result(result)
      rescue StandardError => e
        return soap_fault("Server", e.message)
      end

      soap_response(op_name, result)
    end

    # ── XML helpers (REXML) ──────────────────────────────────────────────

    def find_child(parent, local)
      parent.each_element do |el|
        return el if local_name(el) == local
      end
      nil
    end

    def local_name(element)
      element.name  # REXML already strips the prefix for .name
    end

    # ── Type conversion ──────────────────────────────────────────────────

    def convert_value(value, target_type)
      case target_type.to_s.downcase.to_sym
      when :int, :integer
        value.to_i
      when :float, :double
        value.to_f
      when :boolean, :bool
        %w[true 1 yes].include?(value.downcase)
      else
        value
      end
    end

    # ── Response builders ────────────────────────────────────────────────

    def soap_response(op_name, result)
      parts = []
      parts << '<?xml version="1.0" encoding="UTF-8"?>'
      parts << "<soap:Envelope xmlns:soap=\"#{NS_SOAP_ENV}\">"
      parts << "<soap:Body>"
      parts << "<#{op_name}Response>"

      if result.is_a?(Hash)
        result.each do |k, v|
          if v.nil?
            parts << "<#{k} xsi:nil=\"true\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"/>"
          elsif v.is_a?(Array)
            v.each { |item| parts << "<#{k}>#{escape_xml(item.to_s)}</#{k}>" }
          else
            parts << "<#{k}>#{escape_xml(v.to_s)}</#{k}>"
          end
        end
      end

      parts << "</#{op_name}Response>"
      parts << "</soap:Body>"
      parts << "</soap:Envelope>"
      parts.join("\n")
    end

    def soap_fault(code, message)
      '<?xml version="1.0" encoding="UTF-8"?>' \
      "<soap:Envelope xmlns:soap=\"#{NS_SOAP_ENV}\">" \
      "<soap:Body>" \
      "<soap:Fault>" \
      "<faultcode>#{code}</faultcode>" \
      "<faultstring>#{escape_xml(message)}</faultstring>" \
      "</soap:Fault>" \
      "</soap:Body>" \
      "</soap:Envelope>"
    end

    def escape_xml(s)
      s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end

    def xsd_type(ruby_type)
      return RUBY_TO_XSD[ruby_type] if RUBY_TO_XSD.key?(ruby_type)

      sym = ruby_type.to_s.downcase.to_sym
      RUBY_TO_XSD.fetch(sym, "xsd:string")
    end

    # ── Legacy wrapper ───────────────────────────────────────────────────
    # Keeps backward compatibility with the old Tina4::WSDL::Service API
    # used in demos and existing code.

    class Service
      attr_reader :name, :namespace, :operations

      def initialize(name:, namespace: "http://tina4.com/wsdl")
        @name       = name
        @namespace  = namespace
        @operations = {}
      end

      def add_operation(name, input_params: {}, output_params: {}, &handler)
        @operations[name.to_s] = {
          input: input_params,
          output: output_params,
          handler: handler
        }
      end

      def generate_wsdl(endpoint_url)
        xml = '<?xml version="1.0" encoding="UTF-8"?>'
        xml += "\n<definitions xmlns=\"http://schemas.xmlsoap.org/wsdl/\""
        xml += " xmlns:soap=\"http://schemas.xmlsoap.org/wsdl/soap/\""
        xml += " xmlns:tns=\"#{@namespace}\""
        xml += " xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\""
        xml += " name=\"#{@name}\" targetNamespace=\"#{@namespace}\">\n"

        # Types
        xml += "  <types>\n    <xsd:schema targetNamespace=\"#{@namespace}\">\n"
        @operations.each do |op_name, op|
          xml += _generate_elements(op_name, op[:input], "Request")
          xml += _generate_elements(op_name, op[:output], "Response")
        end
        xml += "    </xsd:schema>\n  </types>\n"

        # Messages
        @operations.each_key do |op_name|
          xml += "  <message name=\"#{op_name}Request\">\n"
          xml += "    <part name=\"parameters\" element=\"tns:#{op_name}Request\"/>\n"
          xml += "  </message>\n"
          xml += "  <message name=\"#{op_name}Response\">\n"
          xml += "    <part name=\"parameters\" element=\"tns:#{op_name}Response\"/>\n"
          xml += "  </message>\n"
        end

        # PortType
        xml += "  <portType name=\"#{@name}PortType\">\n"
        @operations.each_key do |op_name|
          xml += "    <operation name=\"#{op_name}\">\n"
          xml += "      <input message=\"tns:#{op_name}Request\"/>\n"
          xml += "      <output message=\"tns:#{op_name}Response\"/>\n"
          xml += "    </operation>\n"
        end
        xml += "  </portType>\n"

        # Binding
        xml += "  <binding name=\"#{@name}Binding\" type=\"tns:#{@name}PortType\">\n"
        xml += "    <soap:binding style=\"document\" transport=\"http://schemas.xmlsoap.org/soap/http\"/>\n"
        @operations.each_key do |op_name|
          xml += "    <operation name=\"#{op_name}\">\n"
          xml += "      <soap:operation soapAction=\"#{@namespace}/#{op_name}\"/>\n"
          xml += "      <input><soap:body use=\"literal\"/></input>\n"
          xml += "      <output><soap:body use=\"literal\"/></output>\n"
          xml += "    </operation>\n"
        end
        xml += "  </binding>\n"

        # Service
        xml += "  <service name=\"#{@name}\">\n"
        xml += "    <port name=\"#{@name}Port\" binding=\"tns:#{@name}Binding\">\n"
        xml += "      <soap:address location=\"#{endpoint_url}\"/>\n"
        xml += "    </port>\n"
        xml += "  </service>\n"
        xml += "</definitions>"
        xml
      end

      def handle_soap_request(xml_body)
        doc = REXML::Document.new(xml_body)

        # Find Body element (namespace-agnostic)
        body_el = _find_child(doc.root, "Body")
        return _soap_fault("Unknown operation") unless body_el

        op_el = body_el.elements.first
        return _soap_fault("Unknown operation") unless op_el

        op_name = op_el.name
        return _soap_fault("Unknown operation") unless @operations.key?(op_name)

        operation = @operations[op_name]

        # Extract parameters
        params = {}
        operation[:input].each_key do |param_name|
          child = _find_child(op_el, param_name.to_s)
          params[param_name.to_s] = child.text if child
        end

        # Execute handler
        result = operation[:handler].call(params)

        # Build SOAP response
        _build_soap_response(op_name, result)
      rescue StandardError => e
        _soap_fault(e.message)
      end

      private

      def _find_child(parent, local)
        parent.each_element do |el|
          return el if el.name == local
        end
        nil
      end

      def _generate_elements(op_name, params, suffix)
        xml = "      <xsd:element name=\"#{op_name}#{suffix}\">\n"
        xml += "        <xsd:complexType><xsd:sequence>\n"
        params.each do |name, type|
          xsd_type = _ruby_to_xsd_type(type)
          xml += "          <xsd:element name=\"#{name}\" type=\"xsd:#{xsd_type}\"/>\n"
        end
        xml += "        </xsd:sequence></xsd:complexType>\n"
        xml += "      </xsd:element>\n"
        xml
      end

      def _ruby_to_xsd_type(type)
        case type.to_s.downcase
        when "string" then "string"
        when "integer", "int" then "int"
        when "float", "double" then "double"
        when "boolean", "bool" then "boolean"
        when "date" then "date"
        when "datetime" then "dateTime"
        else "string"
        end
      end

      def _build_soap_response(op_name, result)
        xml = '<?xml version="1.0" encoding="UTF-8"?>'
        xml += "<soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\""
        xml += " xmlns:tns=\"#{@namespace}\">"
        xml += "<soap:Body>"
        xml += "<tns:#{op_name}Response>"
        if result.is_a?(Hash)
          result.each { |k, v| xml += "<#{k}>#{_escape_xml(v.to_s)}</#{k}>" }
        else
          xml += "<result>#{_escape_xml(result.to_s)}</result>"
        end
        xml += "</tns:#{op_name}Response>"
        xml += "</soap:Body></soap:Envelope>"
        xml
      end

      def _soap_fault(message)
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">' \
        "<soap:Body><soap:Fault>" \
        "<faultcode>soap:Server</faultcode>" \
        "<faultstring>#{_escape_xml(message)}</faultstring>" \
        "</soap:Fault></soap:Body></soap:Envelope>"
      end

      def _escape_xml(s)
        s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
      end
    end
  end
end
