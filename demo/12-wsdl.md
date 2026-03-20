# WSDL / SOAP

Tina4 Ruby includes a WSDL/SOAP service module for creating and consuming SOAP web services. It generates WSDL XML, parses SOAP request envelopes, and builds SOAP responses.

## Defining a SOAP Service

```ruby
require "tina4"

service = Tina4::WSDL::Service.new(
  name: "CalculatorService",
  namespace: "http://example.com/calculator"
)

# Add operations with typed input/output parameters
service.add_operation("Add",
  input_params: { a: :integer, b: :integer },
  output_params: { result: :integer }
) do |params|
  { result: params["a"].to_i + params["b"].to_i }
end

service.add_operation("Multiply",
  input_params: { x: :float, y: :float },
  output_params: { product: :double }
) do |params|
  { product: params["x"].to_f * params["y"].to_f }
end

service.add_operation("Greet",
  input_params: { name: :string },
  output_params: { greeting: :string }
) do |params|
  { greeting: "Hello, #{params['name']}!" }
end
```

## Serving WSDL and SOAP Endpoints

```ruby
# Serve the WSDL definition
Tina4.get "/soap/calculator", auth: false do |request, response|
  if request.query["wsdl"] || request.query["WSDL"]
    wsdl_xml = service.generate_wsdl("http://localhost:7145/soap/calculator")
    response.xml(wsdl_xml)
  else
    response.text("SOAP endpoint. Append ?wsdl for the WSDL definition.")
  end
end

# Handle SOAP requests
Tina4.post "/soap/calculator", auth: false do |request, response|
  result_xml = service.handle_soap_request(request.body)
  response.xml(result_xml)
end
```

## SOAP Request Example

A client sends a SOAP envelope:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <Add>
      <a>5</a>
      <b>3</b>
    </Add>
  </soap:Body>
</soap:Envelope>
```

The service responds with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
               xmlns:tns="http://example.com/calculator">
  <soap:Body>
    <tns:AddResponse>
      <result>8</result>
    </tns:AddResponse>
  </soap:Body>
</soap:Envelope>
```

## Generated WSDL Structure

The generated WSDL includes:
- **types**: XSD elements for request/response parameters
- **messages**: Input and output messages per operation
- **portType**: Operation definitions
- **binding**: SOAP document/literal binding
- **service**: Endpoint address

## Supported XSD Types

| Ruby Type | XSD Type |
|---|---|
| `:string` | `xsd:string` |
| `:integer`, `:int` | `xsd:int` |
| `:float`, `:double` | `xsd:double` |
| `:boolean`, `:bool` | `xsd:boolean` |
| `:date` | `xsd:date` |
| `:datetime` | `xsd:dateTime` |

## SOAP Fault Handling

If an operation raises an error, the service returns a SOAP fault:

```xml
<soap:Fault>
  <faultcode>soap:Server</faultcode>
  <faultstring>Error message here</faultstring>
</soap:Fault>
```

## Multiple Services

```ruby
calc_service = Tina4::WSDL::Service.new(name: "Calculator", namespace: "http://example.com/calc")
calc_service.add_operation("Add", input_params: { a: :int, b: :int }, output_params: { result: :int }) do |p|
  { result: p["a"].to_i + p["b"].to_i }
end

weather_service = Tina4::WSDL::Service.new(name: "Weather", namespace: "http://example.com/weather")
weather_service.add_operation("GetTemp", input_params: { city: :string }, output_params: { temp: :float }) do |p|
  { temp: 22.5 }
end

# Register each at its own endpoint
Tina4.post "/soap/calc", auth: false do |req, res|
  res.xml(calc_service.handle_soap_request(req.body))
end

Tina4.post "/soap/weather", auth: false do |req, res|
  res.xml(weather_service.handle_soap_request(req.body))
end
```
