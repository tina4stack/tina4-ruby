# Tina4 Ruby — Benchmark Report

**Date:** 2026-03-25 | **Machine:** Apple Silicon (ARM64), 8 cores | **Tool:** `hey` (5000 requests, 50 concurrent, 3 runs, averaged)

---

## 1. Performance

Real HTTP benchmarks — identical JSON and 100-item list endpoints. All frameworks tested on Puma for a fair comparison.

| Framework | JSON req/s | 100-item list req/s | Server | Deps |
|-----------|:---------:|:-------------------:|--------|:----:|
| Roda | 8,159 | 6,232 | Puma | 1 |
| **Tina4 Ruby 3.2** | **17,637** | **11,303** | **Puma** | **0** |
| Sinatra | 7,348 | 5,796 | Puma | 2 |
| Rails 8.1 | 4,918 | 4,007 | Puma | 40+ |

**Key takeaway:** Tina4 Ruby delivers 17,637 req/s — competitive with Roda (19,530), 2.9x faster than Sinatra, and 3.6x faster than Rails, while shipping 98 features. (Ruby is the one language where the zero-dependency claim does NOT hold: the gemspec declares 12 runtime gems, see section 3). Roda is a micro-router with 3 features; Tina4 ships 98.

---

## 1b. Template rendering, Frond vs ERB and Erubi

**Date:** 2026-07-27 | **Machine:** Apple Silicon (ARM64), macOS | **Ruby:** 4.0.2 | **Tool:** `benchmarks/bench_templates.rb` (p50 over batched samples, min 0.25s / 200 iterations)

This category used to be missing, and its absence flattered us. Sections 1 and 2 above
measure request throughput and feature count, where Tina4 competes well. Neither says
anything about template rendering, the one axis where Frond competes head-on with the
engines it replaced. Here are the numbers, and they are the worst of the four languages.

Same page (20-row product list: loop, index, even/odd class, uppercase, 2-decimal
money, conditional footer). **Every engine's output is compared and proven identical
before anything is timed**; a mismatch aborts the run. Each template is compiled ONCE
outside the clock, so this is steady-state render throughput, not compilation.

| Engine | Renders/s (p50) | Renders/s (mean) | Deps |
|--------|:---------------:|:----------------:|:----:|
| ERB (stdlib) | **66,667** | 50,403 | 0 (stdlib) |
| Erubi (what Rails uses) | **65,218** | 50,082 | 1 |
| **Frond (Tina4)** | **1,172** | 1,095 | **0** |

**Key takeaway, stated plainly: Frond is roughly 55x slower than ERB, which ships in
Ruby's own standard library.** Caveat where the data demands one: ERB and Erubi land
within noise of each other and near a clock-quantisation boundary, so the exact multiple
is soft, the order of magnitude is not.

Ruby is the worst of the four for a concrete reason the harness reports: **Ruby has no
AOT compile-to-closure layer**, while PHP (`FrondCompiler`) and Python
(`frond/compiler.py`) both do. ERB compiles a template into a real Ruby method; Frond
walks a tree and calls back into engine primitives per hole.

What Frond does buy is the same template syntax across all four Tina4 languages. That is
a real trade, but it is a trade, not a win. Closing this gap is tracked as the
ahead-of-time compile layer (ADR-0001), and Ruby is the strongest case for it.

Reproduce: `bundle config set --local with "databases:benchmarks" && bundle install && bundle exec ruby benchmarks/bench_templates.rb`


## 2. Feature Comparison (40 of 98 built-in features)

Tina4 ships **98 built-in features**. The table below compares the subset that has a
meaningful equivalent in the competing frameworks, so it is a like-for-like comparison
rather than the full inventory. Everything listed ships with the core install, with no
extra packages needed.

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
| **Tina4** | **40/40** | **0** | **17,637** |
| Rails 8 | 20/40 | 40+ | 4,918 |
| Sinatra | 4/40 | 2 | 6,016 |
| Roda | 3/40 | 1 | 19,530 |

---

## 3. Deployment Size

**Measured 2026-07-27** on macOS (Apple Silicon) by installing each package for real.
Nothing in this table is estimated. The command that produced it is named below.

Command: `gem install <gem> --install-dir ./h`, then `du -sh h/gems`.

| Framework | Install Size (with deps) | Gems installed |
|-----------|:----------------------:|:--------------:|
| roda | **2 MB** | 2 |
| sinatra | 2 MB | 8 |
| **Tina4 Ruby** | **16 MB** (framework gem alone 3.1 MB) | **18** |
| rails | 63 MB | 66 |

**Two corrections, both material.**

1. This table claimed **~900 KB**. The framework gem alone is **3.1 MB**, and a real
   `gem install tina4` pulls **16 MB across 18 gems**.
2. This table claimed **0 dependencies**, and that is **false for Ruby**. The gemspec
   declares 12 runtime dependencies: `rack`, `rackup`, `puma`, `jwt`, `net-smtp`,
   `net-imap`, `json`, `rexml`, `webrick`, `logger`, `base64`, `sqlite3`. Ruby is the one
   language where the zero-dependency promise does not hold, and the docs should not have
   said otherwise.

Also worth knowing when you install: `gem install tina4` installs a 2-file alias gem. The
framework itself is the `tina4ruby` gem that the alias depends on.

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
