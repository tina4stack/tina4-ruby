# frozen_string_literal: true

module Tina4
  module WSDL
    class Service
      attr_reader :name, :namespace, :operations

      def initialize(name:, namespace: "http://tina4.com/wsdl")
        @name = name
        @namespace = namespace
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
          xml += generate_elements(op_name, op[:input], "Request")
          xml += generate_elements(op_name, op[:output], "Response")
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
        # Simple SOAP envelope parser
        op_name = nil
        params = {}

        @operations.each_key do |name|
          if xml_body.include?(name)
            op_name = name
            break
          end
        end

        return soap_fault("Unknown operation") unless op_name

        operation = @operations[op_name]

        # Extract parameters from XML
        operation[:input].each_key do |param_name|
          if xml_body =~ /<#{param_name}>(.*?)<\/#{param_name}>/m
            params[param_name.to_s] = Regexp.last_match(1)
          end
        end

        # Execute handler
        result = operation[:handler].call(params)

        # Build SOAP response
        build_soap_response(op_name, result)
      rescue => e
        soap_fault(e.message)
      end

      private

      def generate_elements(op_name, params, suffix)
        xml = "      <xsd:element name=\"#{op_name}#{suffix}\">\n"
        xml += "        <xsd:complexType><xsd:sequence>\n"
        params.each do |name, type|
          xsd_type = ruby_to_xsd_type(type)
          xml += "          <xsd:element name=\"#{name}\" type=\"xsd:#{xsd_type}\"/>\n"
        end
        xml += "        </xsd:sequence></xsd:complexType>\n"
        xml += "      </xsd:element>\n"
        xml
      end

      def ruby_to_xsd_type(type)
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

      def build_soap_response(op_name, result)
        xml = '<?xml version="1.0" encoding="UTF-8"?>'
        xml += '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"'
        xml += " xmlns:tns=\"#{@namespace}\">"
        xml += "<soap:Body>"
        xml += "<tns:#{op_name}Response>"
        if result.is_a?(Hash)
          result.each { |k, v| xml += "<#{k}>#{v}</#{k}>" }
        else
          xml += "<result>#{result}</result>"
        end
        xml += "</tns:#{op_name}Response>"
        xml += "</soap:Body></soap:Envelope>"
        xml
      end

      def soap_fault(message)
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">' \
        "<soap:Body><soap:Fault>" \
        "<faultcode>soap:Server</faultcode>" \
        "<faultstring>#{message}</faultstring>" \
        "</soap:Fault></soap:Body></soap:Envelope>"
      end
    end
  end
end
