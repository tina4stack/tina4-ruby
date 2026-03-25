# Write Tina4 Tests

Write Minitest tests for a Tina4 feature.

## Instructions

1. Create test file in `tests/` matching the module name
2. Use Minitest with standard assertions
3. Test both happy path and error cases

## Test Structure

```ruby
require "minitest/autorun"

class TestFeatureName < Minitest::Test
  def test_happy_path
    # Test the expected behavior
    result = do_something
    assert_equal expected, result
  end

  def test_edge_case
    # Test boundary conditions
  end

  def test_error_handling
    # Test error cases
    assert_raises(ArgumentError) do
      do_something_bad
    end
  end
end
```

## Testing ORM Models

```ruby
require "minitest/autorun"
require_relative "../src/orm/product"

class TestProduct < Minitest::Test
  def test_create_from_hash
    p = Product.new({ "name" => "Widget", "price" => 9.99 })
    assert_equal "Widget", p.name
    assert_equal 9.99, p.price
  end

  def test_to_hash
    p = Product.new({ "name" => "Widget", "price" => 9.99 })
    d = p.to_hash
    assert_equal "Widget", d["name"]
  end

  def test_defaults
    p = Product.new
    assert_equal 1, p.active
  end
end
```

## Testing Routes (with mock request/response)

```ruby
require "minitest/autorun"
require "ostruct"

class TestProductRoutes < Minitest::Test
  def test_list_products
    require_relative "../src/routes/products"

    request = OpenStruct.new(params: { "page" => "1", "limit" => "10" })
    responses = []
    response = OpenStruct.new(json: ->(data, code = 200) { responses << [data, code] })

    # Call the route handler
    list_products(request, response)
    assert_equal 1, responses.length
  end

  def test_create_product
    require_relative "../src/routes/products"

    request = OpenStruct.new(body: { "name" => "Test", "price" => 5.0 })
    responses = []
    response = OpenStruct.new(json: ->(data, code = 200) { responses << [data, code] })

    create_product(request, response)
    assert_equal 201, responses[0][1]
  end
end
```

## Testing Services

```ruby
require "minitest/autorun"
require "minitest/mock"

class TestPaymentService < Minitest::Test
  def test_charge_success
    require_relative "../src/app/payment_service"
    svc = PaymentService.new

    mock_result = { "http_code" => 200, "body" => { "id" => "ch_1" }, "error" => nil }
    svc.instance_variable_get(:@api).stub(:post, mock_result) do
      result = svc.charge(amount: 1000)
      assert result["success"]
    end
  end

  def test_charge_failure
    require_relative "../src/app/payment_service"
    svc = PaymentService.new

    mock_result = { "http_code" => 400, "body" => nil, "error" => "Card declined" }
    svc.instance_variable_get(:@api).stub(:post, mock_result) do
      result = svc.charge(amount: 1000)
      refute result["success"]
    end
  end
end
```

## Running Tests

```bash
# All tests
ruby -Itest tests/**/*_test.rb

# Or with rake
rake test

# Single file
ruby -Itest tests/test_products.rb

# Single test
ruby -Itest tests/test_products.rb -n test_create

# With verbose output
ruby -Itest tests/test_products.rb -v
```

## Key Rules

- Test file names: `test_<feature>.rb`
- Test class names: `TestFeatureName`
- Test method names: `test_<what_it_tests>`
- Mock external dependencies, not internal framework code
- Test behavior, not implementation details
- Aim for >95% coverage on new code
