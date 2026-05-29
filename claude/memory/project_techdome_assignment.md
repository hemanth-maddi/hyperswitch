---
name: project-techdome-assignment
description: "Techdome Senior Engineer take-home — BIN-prefix routing in Hyperswitch fork, due 48h from receipt"
metadata: 
  node_type: memory
  type: project
  originSessionId: df3bc639-66b9-40f0-b491-936dd26f4745
---

BIN-prefix routing implemented on the Hyperswitch fork (juspay/hyperswitch) for Techdome take-home.

**Architecture (2026-05-28, final):** Added `BinBased` as a new variant of `StaticRoutingAlgorithm` — the existing routing algorithm enum. Config is stored in DB just like other algorithms (JSON in `algorithm_data`). Loaded into `CachedAlgorithm::BinBased` at runtime. Uses longest-prefix match.

**Files changed:**
- `crates/api_models/src/routing.rs` — `BinRule`, `BinBasedRoutingConfig`, `BinBased` enum variant in `StaticRoutingAlgorithm`/`RoutingAlgorithmSerde`/`RoutingAlgorithmKind`
- `crates/router/src/types/api/routing.rs` — Re-export `BinBasedRoutingConfig`, `BinRule`
- `crates/router/src/core/payments/routing.rs` — `CachedAlgorithm::BinBased`, `perform_bin_routing()`, 3 match arm updates, 6 inline unit tests
- `crates/router/src/core/routing/helpers.rs` — Connector validation for BinBased
- `crates/router/src/core/routing/transformers.rs` — Maps `BinBased` → storage `Advanced` (avoids DB migration)
- `crates/router/src/core/routing.rs` — Skip BinBased in decision-engine migration paths
- `docker-compose-demo.yml` — Builds from local source (Rust cache volumes)
- `scripts/demo_bin_routing.sh` — E2E demo: creates merchant → routing algo → fires RuPay + Visa payments
- `Makefile` — `make demo`, `make test-bin-routing`
- `README.md` — BIN routing quick-start (< 10 min onboarding)
- `DECISIONS.md` — Design rationale

**Tests:** 6 unit tests, all passing. Run with `make test-bin-routing` (needs `PQ_LIB_DIR=/opt/homebrew/opt/libpq/lib` on macOS).

**Known tradeoff:** `RoutingAlgorithmKind::BinBased` maps to storage enum `Advanced` to avoid a DB migration (documented in DECISIONS.md).
