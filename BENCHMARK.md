# Tina4 Ruby — Benchmark Report

**Date:** 2026-03-23 | **Machine:** Apple Silicon (ARM64), 8 cores | **Tool:** `hey` (5000 requests, 50 concurrent, 3 runs, median)

---

## 1. Performance

Real HTTP benchmarks — identical JSON and 100-item list endpoints, WEBrick server.

| Rank | Framework | JSON req/s | List req/s | Server | Deps |
|:----:|-----------|:---------:|:----------:|--------|:----:|
| 1 | Roda | 4,094 | 4,544 | WEBrick | 1 |
| 2 | Sinatra | 2,905 | 2,184 | WEBrick | 2 |
| — | **Tina4 Ruby** | **—** | **—** | **—** | **0** |
| — | Rails 8 | — | — | — | 40+ |

> **Note:** Tina4 Ruby and Rails were not benchmarked in this round due to setup issues. The published gem (v3.0.0) has server startup issues on Ruby 4.0. The local v3.2.0 contains these fixes but has not been published to RubyGems yet. Tina4 Ruby is expected to perform similarly to Roda based on shared architectural patterns (lightweight routing, WEBrick).

---

## 2. Feature Comparison (38 features)

Ships with core install, no extra packages needed.

| Feature | Tina4 | Sinatra | Roda | Rails |
|---------|:-----:|:-------:|:----:|:-----:|
| **CORE WEB** | | | | |
| Routing (decorators) | Y | Y | Y | Y |
| Typed path parameters | Y | - | Y | Y |
| Middleware system | Y | Y | Y | Y |
| Static file serving | Y | Y | - | Y |
| CORS built-in | Y | - | - | - |
| Rate limiting | Y | - | - | Y |
| WebSocket | Y | - | - | Y |
| **DATA** | | | | |
| ORM | Y | - | - | Y |
| 5 database drivers | Y | - | - | Y |
| Migrations | Y | - | - | Y |
| Seeder / fake data | Y | - | - | - |
| Sessions | Y | Y | - | Y |
| Response caching | Y | - | - | Y |
| **AUTH** | | | | |
| JWT built-in | Y | - | - | - |
| Password hashing | Y | - | - | Y |
| CSRF protection | Y | - | - | Y |
| **FRONTEND** | | | | |
| Template engine | Y | Y | - | Y |
| CSS framework | Y | - | - | Y |
| SCSS compiler | Y | - | - | Y |
| Frontend JS helpers | Y | - | - | Y |
| **API** | | | | |
| Swagger/OpenAPI | Y | - | - | - |
| GraphQL | Y | - | - | - |
| SOAP/WSDL | Y | - | - | - |
| HTTP client | Y | - | - | Y |
| Queue system | Y | - | - | Y |
| **DEV EXPERIENCE** | | | | |
| CLI scaffolding | Y | - | - | Y |
| Dev admin dashboard | Y | - | - | - |
| Error overlay | Y | - | - | Y |
| Live reload | Y | - | - | Y |
| Auto-CRUD generator | Y | - | - | - |
| Gallery / examples | Y | - | - | - |
| AI assistant context | Y | - | - | - |
| Inline testing | Y | - | - | - |
| **ARCHITECTURE** | | | | |
| Zero dependencies | Y | - | - | - |
| Dependency injection | Y | - | - | - |
| Event system | Y | - | - | Y |
| i18n / translations | Y | - | - | Y |
| HTML builder | Y | - | - | - |

### Feature Count

| Framework | Features | Deps | JSON req/s |
|-----------|:-------:|:----:|:---------:|
| **Tina4** | **38/38** | **0** | *not yet benchmarked* |
| Rails 8 | 20/38 | 40+ | *not yet benchmarked* |
| Sinatra | 4/38 | 2 | 2,905 |
| Roda | 3/38 | 1 | 4,094 |

---

## 3. Deployment Size

| Framework | Install Size | Dependencies |
|-----------|:----------:|:------------:|
| **Tina4 Ruby** | **~900 KB** | **0** |
| Roda | ~1 MB | 1 |
| Sinatra | ~5 MB | 2 |
| Rails | 40+ MB | 40+ |

Zero dependencies means core size **is** deployment size. No gem bloat.

---

## 4. CO2 / Carbonah

Estimated emissions per HTTP benchmark run (5000 requests on Apple Silicon, 15W TDP).

Only Roda and Sinatra were benchmarked; Tina4 and Rails are excluded from this calculation.

| Framework | JSON req/s | Duration (s) | Est. Energy (kWh) | Est. CO2 (g) |
|-----------|:---------:|:------------:|:-----------------:|:------------:|
| Roda | 4,094 | 1.221 | 0.0000051 | 0.0024 |
| Sinatra | 2,905 | 1.721 | 0.0000072 | 0.0034 |

*Calculation: duration = 5000 / req_s; energy = duration x 15W / 3,600,000; CO2 = energy x 475 g/kWh (world average).*

**Roda uses ~30% less energy than Sinatra** to serve the same 5000 requests thanks to higher throughput.

---

## 5. How to Run

Install `hey`:

```bash
brew install hey
```

Run benchmarks manually:

```bash
# Start the framework server (e.g., Roda on port 9292)
cd benchmarks/roda && ruby app.rb &

# JSON endpoint
hey -n 5000 -c 50 http://localhost:9292/json

# List endpoint
hey -n 5000 -c 50 http://localhost:9292/list

# Take median of 3 runs
```

Automated benchmarks are maintained in the `tina4-python` repository:

```bash
cd ../tina4-python/benchmarks
python benchmark.py --ruby
```

Full cross-language suite:

```bash
python benchmark.py --all
```

Results are written to `benchmarks/results/ruby.json`.

See the [tina4-python benchmarks README](https://github.com/tina4stack/tina4-python/tree/main/benchmarks) for prerequisites and detailed instructions.

---

*Generated from benchmark data — https://tina4.com*
