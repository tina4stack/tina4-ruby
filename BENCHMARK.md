# Tina4 Ruby — Benchmark Report

**Date:** 2026-03-22 | **Machine:** Apple Silicon (ARM64) | **Tool:** `hey` (5000 requests, 50 concurrent, 3 runs, median)

---

## 1. Performance

Real HTTP benchmarks — identical JSON endpoint, development servers.

| Framework | JSON req/s | 100-item list req/s | Server | Deps |
|-----------|:---------:|:-------------------:|--------|:----:|
| Roda | 20,964 | — | Puma | 1 |
| Sinatra | 9,364 | 7,192 | Puma | 5 |
| **Tina4 Ruby 3.0** | **9,102** | **7,586** | **WEBrick** | **0** |
| Rails 7 | 5,060 | 4,358 | Puma | 40 |

**Key takeaway:** Tina4 on WEBrick matches Sinatra on Puma while shipping 38 features with 0 dependencies. On Puma, Tina4 reaches ~22K req/s (2.8x improvement).

### Production Server Results

| Framework | Dev Server | Dev JSON/s | Prod Server | Prod JSON/s | Change |
|-----------|-----------|:---------:|-------------|:---------:|:------:|
| **Tina4 Ruby** | WEBrick | 9,102 | Puma | **22,784** | **2.5x** |
| Sinatra | Puma | 9,364 | Puma (tuned) | ~12,000 | +28% |
| Rails | Puma | 5,060 | Puma (tuned) | ~6,500 | +28% |

### Warmup Time

| Framework | Warmup (ms) |
|-----------|:-----------:|
| Sinatra | 85 |
| **Tina4** | **102** |
| Rails | 222 |

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
| **Tina4** | **38/38** | **0** | **9,102** |
| Rails | 20/38 | 40 | 5,060 |
| Sinatra | 4/38 | 5 | 9,364 |
| Roda | 3/38 | 1 | 20,964 |

---

## 3. Deployment Size

| Framework | Install Size | Dependencies |
|-----------|:----------:|:------------:|
| **Tina4 Ruby** | **892 KB** | **0** |
| Sinatra | 5 MB | 5 |
| Roda | 1 MB | 1 |
| Rails | 40+ MB | 40 |

Zero dependencies means core size **is** deployment size. No gem bloat.

---

## 4. CO2 / Carbonah

Estimated emissions per HTTP benchmark run (5000 requests on Apple Silicon, 15W TDP).

| Framework | JSON req/s | Est. Energy (kWh) | Est. CO2 (g) |
|-----------|:---------:|:-----------------:|:------------:|
| **Tina4** | 9,102 | 0.0000229 | 0.0109 |
| Roda | 20,964 | 0.0000099 | 0.0047 |
| Sinatra | 9,364 | 0.0000222 | 0.0106 |
| Rails | 5,060 | 0.0000411 | 0.0195 |

*CO2 calculated at world average 475g CO2/kWh. Lower req/s = longer to serve 5000 requests = more energy.*

### Tina4 Test Suite Emissions

| Metric | Value |
|--------|-------|
| Test Execution Time | 6.86s |
| Tests | 1,577 |
| CO2 per Run | 0.014g |
| Tests per Second | 221.0 |
| Annual CI (10 runs/day) | 0.051g CO2/year |

**Carbonah Rating: A+**

---

## 5. How to Run

Benchmarks are maintained in the `tina4-python` repository's `benchmarks/` folder.

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
