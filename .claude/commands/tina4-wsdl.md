# Create a Tina4 SOAP/WSDL Service

Create a SOAP web service with auto-generated WSDL from Ruby type annotations.

## Instructions

1. Create a WSDL service class in `src/app/`
2. Define operations with type signatures
3. Create a route to serve the WSDL and handle SOAP requests

## Service (`src/app/calculator_service.rb`)

```ruby
require "tina4/wsdl"

class CalculatorService < Tina4::WSDL
  def initialize
    super(
      name: "CalculatorService",
      namespace: "http://example.com/calculator",
      url: "http://localhost:7145/soap/calculator"
    )
  end

  wsdl_operation returns: Float
  def add(a: Float, b: Float)
    a + b
  end

  wsdl_operation returns: Float
  def multiply(a: Float, b: Float)
    a * b
  end

  wsdl_operation returns: Float
  def divide(a: Float, b: Float)
    raise ArgumentError, "Division by zero" if b == 0
    a / b
  end
end

CALCULATOR = CalculatorService.new
```

## Route (`src/routes/soap.rb`)

```ruby
require "tina4/router"
require_relative "../app/calculator_service"

Tina4::Router.get "/soap/calculator",
  noauth: true do |request, response|
  wsdl_xml = CALCULATOR.generate
  response.xml(wsdl_xml)
end

Tina4::Router.post "/soap/calculator",
  noauth: true do |request, response|
  result = CALCULATOR.handle(request)
  response.xml(result)
end
```

## Type Mapping

| Ruby Type | XSD Type |
|---|---|
| `String` | `xsd:string` |
| `Integer` | `xsd:int` |
| `Float` | `xsd:double` |
| `TrueClass`/`FalseClass` | `xsd:boolean` |

## Lifecycle Hooks

```ruby
class MyService < Tina4::WSDL
  def on_request(operation, params)
    # Called before operation executes -- validate, log, transform input
    puts "Calling #{operation} with #{params}"
    params  # Return modified params or original
  end

  def on_result(operation, result)
    # Called after operation executes -- transform output
    result
  end
end
```

## SOAP Client Request Example

```xml
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                  xmlns:calc="http://example.com/calculator">
    <soapenv:Body>
        <calc:add>
            <a>10</a>
            <b>20</b>
        </calc:add>
    </soapenv:Body>
</soapenv:Envelope>
```

## Key Rules

- Service classes go in `src/app/`, routes in `src/routes/`
- Use Ruby type annotations -- WSDL is auto-generated from them
- GET returns the WSDL definition, POST processes SOAP requests
- Use lifecycle hooks for logging, validation, and transformation
- All XML parsing uses stdlib `REXML` -- zero dependencies
