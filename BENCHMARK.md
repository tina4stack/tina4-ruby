# Tina4 Ruby — Benchmark Report

**Date:** 2026-03-25 | **Machine:** Apple Silicon (ARM64), 8 cores | **Tool:** `hey` (5000 requests, 50 concurrent, 3 runs, averaged)

---

## 1. Performance

Real HTTP benchmarks — identical JSON and 100-item list endpoints. All frameworks tested on Puma for a fair comparison.

| Framework | JSON req/s | 100-item list req/s | Server | Deps |
|-----------|:---------:|:-------------------:|--------|:----:|
| Roda | 19,530 | 10,746 | Puma | 1 |
| **Tina4 Ruby 3.2** | **17,637** | **11,303** | **Puma** | **0** |
| Sinatra | 6,016 | 4,139 | Puma | 2 |
| Rails 8.1 | 4,918 | 4,007 | Puma | 40+ |

**Key takeaway:** Tina4 Ruby delivers 17,637 req/s — competitive with Roda (19,530), 2.9x faster than Sinatra, and 3.6x faster than Rails, while shipping 38 features with 0 core dependencies. Roda is a micro-router with 3 features; Tina4 ships 38.

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
| **Tina4** | **38/38** | **0** | **17,637** |
| Rails 8 | 20/38 | 40+ | 4,918 |
| Sinatra | 4/38 | 2 | 6,016 |
| Roda | 3/38 | 1 | 19,530 |

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

All frameworks on Puma.

| Framework | JSON req/s | Duration (s) | Est. Energy (kWh) | Est. CO2 (g) |
|-----------|:---------:|:------------:|:-----------------:|:------------:|
| Roda | 19,530 | 0.256 | 0.0000011 | 0.0005 |
| **Tina4** | **17,637** | **0.2835** | **0.0000012** | **0.0006** |
| Sinatra | 6,016 | 0.831 | 0.0000035 | 0.0016 |
| Rails | 4,918 | 1.017 | 0.0000042 | 0.0020 |

*Calculation: duration = 5000 / req_s; energy = duration × 15W / 3,600,000; CO2 = energy × 475 g/kWh (world average).*

**Rails emits 3.3x more CO2** per benchmark run than Tina4. Tina4 is competitive with Roda in efficiency while shipping 35 more features.

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
