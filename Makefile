# = Parameters
# Override envars using -e

#
# = Common
#

# Checks two given strings for equality.
eq = $(if $(or $(1),$(2)),$(and $(findstring $(1),$(2)),\
                                $(findstring $(2),$(1))),1)


ROOT_DIR_WITH_SLASH := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(realpath $(ROOT_DIR_WITH_SLASH))

#
# = Targets
#

.PHONY : \
	doc \
	fmt \
	clippy \
	test \
	audit \
	git.sync \
	build \
	push \
	shell \
	run \
	start \
	stop \
	rm \
	release


# Check a local package and all of its dependencies for errors
# 
# Usage :
#	make check
check:
	cargo check


# Compile application for running on local machine
#
# Usage :
#	make build
build :
	cargo build

# Generate crates documentation from Rust sources.
#
# Usage :
#	make doc [private=(yes|no)] [open=(yes|no)] [clean=(no|yes)]

doc :
ifeq ($(clean),yes)
	@rm -rf target/doc/
endif
	cargo doc --all-features --package router \
		$(if $(call eq,$(private),no),,--document-private-items) \
		$(if $(call eq,$(open),no),,--open)

# Format Rust sources with rustfmt.
#
# Usage :
#	make fmt [dry_run=(no|yes)]

fmt :
	cargo +nightly fmt --all $(if $(call eq,$(dry_run),yes),-- --check,)

# Lint Rust sources with Clippy.
#
# Usage :
#	make clippy

clippy :
	cargo clippy --all-features --all-targets -- -D warnings

# Build the DSL crate as a WebAssembly JS library
#
# Usage :
# 	make euclid-wasm

euclid-wasm:
	wasm-pack build --target web --out-dir $(ROOT_DIR)/wasm --out-name euclid $(ROOT_DIR)/crates/euclid_wasm  -- --features dummy_connector,v1

# Run Rust tests of project.
#
# Usage :
#	make test

test :
	cargo test --all-features


# Next-generation test runner for Rust.
# cargo nextest ignores the doctests at the moment. So if you are using it locally you also have to run `cargo test --doc`.
# Usage:
# 	make nextest

nextest:
	cargo nextest run

# Run format clippy test and tests.
#
# Usage :
#	make precommit

precommit : fmt clippy test


hack:
	cargo hack check --workspace --each-feature --all-targets --exclude-features 'v2 payment_v2'

# ──────────────────────────────────────────────────────────────────────────────
# BIN-based routing demo
# ──────────────────────────────────────────────────────────────────────────────

# Run the BIN-based routing end-to-end demo.
#
# What it does:
#   1. Tears down any previous containers (idempotent)
#   2. Starts Postgres + Redis in Docker (fast, no compilation)
#   3. Runs DB migrations via a temporary Debian container
#   4. Builds + starts the Hyperswitch server natively (cargo run)
#   5. Waits for the server health check, then runs demo_bin_routing.sh
#
# Requirements: Rust toolchain, libpq (brew install libpq on macOS)
#
# Usage:
#   make demo

.PHONY: demo
demo:
	@echo "==> Tearing down any previous run (volumes included for fresh DB)..."
	docker compose -f docker-compose-demo.yml down --remove-orphans --volumes
	@pkill -f "target/debug/router" 2>/dev/null || true
	@echo "==> Pulling images (prevents OOM from concurrent pulls during startup)..."
	docker compose -f docker-compose-demo.yml pull --quiet pg redis-standalone superposition migration_runner 2>/dev/null || true
	@echo "==> Starting Postgres + Redis..."
	docker compose -f docker-compose-demo.yml up -d pg redis-standalone
	@echo "==> Waiting for Postgres + Redis to be healthy..."
	@until docker compose -f docker-compose-demo.yml ps pg | grep -q healthy; do sleep 2; done
	@echo "==> Starting Superposition (depends on Redis)..."
	docker compose -f docker-compose-demo.yml up -d superposition
	@echo "==> Waiting for Superposition to be healthy on :8081..."
	@for i in $$(seq 1 30); do \
		curl -sf http://localhost:8081/health >/dev/null 2>&1 && echo "==> Superposition is up!" && break; \
		[ $$i -eq 30 ] && echo "ERROR: Superposition failed to start" && docker compose -f docker-compose-demo.yml logs superposition | tail -20 && exit 1; \
		sleep 3; \
	done
	@echo "==> Initialising Superposition workspace (dimension + default config)..."
	@curl -sf -X POST http://localhost:8081/dimension \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer 123456" \
		-H "x-org-id: localorg" \
		-H "x-tenant: dev" \
		-d '{"dimension":"processor_merchant_id","priority":10,"position":1,"description":"Hyperswitch merchant ID","schema":{"type":"string"},"function_name":null,"change_reason":"demo-init"}' \
		>/dev/null 2>&1 || true
	@curl -sf -X POST http://localhost:8081/default-config \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer 123456" \
		-H "x-org-id: localorg" \
		-H "x-tenant: dev" \
		-d '{"key":"fingerprint_secret","value":"","schema":{"type":"string"},"function_name":null,"change_reason":"demo-init","description":"Merchant fingerprint secret"}' \
		>/dev/null 2>&1 || true
	@echo "==> Superposition workspace initialised."
	@echo "==> Running DB migrations..."
	docker compose -f docker-compose-demo.yml up migration_runner
	@echo "==> Building Hyperswitch server (first build: ~10 min, cached: ~30 s)..."
	@bash -c '\
		export PATH="$$HOME/.cargo/bin:$$PATH"; \
		LIBPQ="$$(brew --prefix libpq 2>/dev/null)"; \
		export PQ_LIB_DIR="$$LIBPQ/lib"; \
		export LIBRARY_PATH="$$LIBPQ/lib:$$LIBRARY_PATH"; \
		cargo build --features v1 --bin router'
	@echo "==> Starting Hyperswitch server in background..."
	@pkill -f "target/debug/router" 2>/dev/null || true
	@bash -c '\
		export PATH="$$HOME/.cargo/bin:$$PATH"; \
		LIBPQ="$$(brew --prefix libpq 2>/dev/null)"; \
		export PQ_LIB_DIR="$$LIBPQ/lib"; \
		export LIBRARY_PATH="$$LIBPQ/lib:$$LIBRARY_PATH"; \
		export ROUTER__MASTER_DATABASE__HOST=localhost; \
		export ROUTER__REPLICA_DATABASE__HOST=localhost; \
		export ROUTER__REDIS__HOST=localhost; \
		export ROUTER__SUPERPOSITION__ENDPOINT=http://localhost:8081; \
		cargo run --features v1 --bin router -- -f ./config/docker_compose.toml \
			&> /tmp/hyperswitch-server.log & echo $$! > /tmp/hs-server.pid'
	@echo "==> Waiting for server to be ready on :8080 (check /tmp/hyperswitch-server.log for progress)..."
	@for i in $$(seq 1 60); do \
		curl -sf http://localhost:8080/health >/dev/null 2>&1 && echo "==> Server is up!" && break; \
		if [ $$i -eq 60 ]; then \
			echo "ERROR: Server did not start in time. Last logs:"; \
			tail -20 /tmp/hyperswitch-server.log; \
			exit 1; \
		fi; \
		sleep 3; \
	done
	@echo "==> Running BIN routing demo..."
	bash scripts/demo_bin_routing.sh
	@echo ""
	@echo "Server running (PID $$(cat /tmp/hs-server.pid)). To stop: kill $$(cat /tmp/hs-server.pid)"

# Run just the BIN routing unit tests (no server required).
#
# Usage:
#   make test-bin-routing

.PHONY: test-bin-routing
test-bin-routing:
	cargo test --features v1 -p router bin_routing_tests -- --nocapture
