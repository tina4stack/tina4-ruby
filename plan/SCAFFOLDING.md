# Rich Scaffolding Plan — Ruby

## Commands

| Command | Output |
|---------|--------|
| `generate model Product --fields "name:string,price:float"` | `src/orm/product.rb` + `migrations/TS_create_product.sql` |
| `generate route products --model Product` | `src/routes/products.rb` with ORM CRUD |
| `generate crud Product --fields "name:string,price:float"` | model + migration + routes + template + test |
| `generate migration add_category` | `migrations/TS_add_category.sql` + `.down.sql` |
| `generate middleware AuthCheck` | `src/middleware/auth_check.rb` with before/after |
| `generate test products` | `spec/products_spec.rb` with RSpec |

## Field Type Mapping

| CLI | Ruby DSL | SQL |
|-----|----------|-----|
| string | string_field | VARCHAR(255) |
| int/integer | integer_field | INTEGER |
| float/decimal | float_field | REAL |
| bool/boolean | boolean_field | INTEGER |
| text | text_field | TEXT |
| datetime | datetime_field | DATETIME |
| blob | blob_field | BLOB |

## Table Convention
- Singular: `Product` → `product`
- Override: `plural_table true` → `products`

## DX Fixes
- `--no-browser` flag on serve
- Kill existing process on port
- Add plural_table DSL to FieldTypes

## Files to Modify
- `lib/tina4/cli.rb` — all generators, field parser, port-kill
- `lib/tina4/field_types.rb` — plural_table DSL

## Tests
- `spec/cli_spec.rb` — 10 test cases
