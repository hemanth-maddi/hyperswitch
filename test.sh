#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- ADD THIS GLOBALLY AT THE TOP ---
export PATH="$HOME/.cargo/bin:$PATH"
LIBPQ="$(brew --prefix libpq 2>/dev/null || true)"
if [ -n "$LIBPQ" ]; then
    export PQ_LIB_DIR="$LIBPQ/lib"
    export LIBRARY_PATH="$LIBPQ/lib:$LIBRARY_PATH"
    export LDFLAGS="-L$LIBPQ/lib"
    export PKG_CONFIG_PATH="$LIBPQ/lib/pkgconfig"
fi
# ------------------------------------

# Function for the 'demo' target
run_demo() {
    echo "==> Tearing down any previous run (volumes included for fresh DB)..."
    docker compose -f docker-compose-demo.yml down --remove-orphans --volumes
    
    pkill -f "target/debug/router" 2>/dev/null || true
    
    echo "==> Pulling images (prevents OOM from concurrent pulls during startup)..."
    docker compose -f docker-compose-demo.yml pull --quiet pg redis-standalone superposition migration_runner 2>/dev/null || true
    
    echo "==> Starting Postgres + Redis..."
    docker compose -f docker-compose-demo.yml up -d pg redis-standalone
    
    echo "==> Waiting for Postgres + Redis to be healthy..."
    until docker compose -f docker-compose-demo.yml ps pg | grep -q healthy; do 
        sleep 2
    done
    
    echo "==> Starting Superposition (depends on Redis)..."
    docker compose -f docker-compose-demo.yml up -d superposition
    
    echo "==> Waiting for Superposition to be healthy on :8081..."
    for i in $(seq 1 30); do
        if curl -sf http://localhost:8081/health >/dev/null 2>&1; then
            echo "==> Superposition is up!"
            break
        fi
        if [ "$i" -eq 30 ]; then
            echo "ERROR: Superposition failed to start"
            docker compose -f docker-compose-demo.yml logs superposition | tail -20
            exit 1
        fi
        sleep 3
    done
    
    echo "==> Initialising Superposition workspace (dimension + default config)..."
    curl -sf -X POST http://localhost:8081/dimension \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer 123456" \
        -H "x-org-id: localorg" \
        -H "x-tenant: dev" \
        -d '{"dimension":"processor_merchant_id","priority":10,"position":1,"description":"Hyperswitch merchant ID","schema":{"type":"string"},"function_name":null,"change_reason":"demo-init"}' \
        >/dev/null 2>&1 || true
        
    curl -sf -X POST http://localhost:8081/default-config \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer 123456" \
        -H "x-org-id: localorg" \
        -H "x-tenant: dev" \
        -d '{"key":"fingerprint_secret","value":"","schema":{"type":"string"},"function_name":null,"change_reason":"demo-init","description":"Merchant fingerprint secret"}' \
        >/dev/null 2>&1 || true
        
    echo "==> Superposition workspace initialised."
    
    echo "==> Running DB migrations..."
    docker compose -f docker-compose-demo.yml up migration_runner
    
    echo "==> Building Hyperswitch server (first build: ~10 min, cached: ~30 s)..."
    export PATH="$HOME/.cargo/bin:$PATH"
    LIBPQ="$(brew --prefix libpq 2>/dev/null || true)"
    if [ -n "$LIBPQ" ]; then
        export PQ_LIB_DIR="$LIBPQ/lib"
        export LIBRARY_PATH="$LIBPQ/lib:$LIBRARY_PATH"
    fi
    cargo build --features v1 --bin router
    
    echo "==> Starting Hyperswitch server in background..."
    pkill -f "target/debug/router" 2>/dev/null || true
    
    export ROUTER__MASTER_DATABASE__HOST=localhost
    export ROUTER__REPLICA_DATABASE__HOST=localhost
    export ROUTER__REDIS__HOST=localhost
    export ROUTER__SUPERPOSITION__ENDPOINT=http://localhost:8081
    
    cargo run --features v1 --bin router -- -f ./config/docker_compose.toml \
        &> /tmp/hyperswitch-server.log & 
    echo $! > /tmp/hs-server.pid
    
    echo "==> Waiting for server to be ready on :8080 (check /tmp/hyperswitch-server.log for progress)..."
    for i in $(seq 1 60); do
        if curl -sf http://localhost:8080/health >/dev/null 2>&1; then
            echo "==> Server is up!"
            break
        fi
        if [ "$i" -eq 60 ]; then
            echo "ERROR: Server did not start in time. Last logs:"
            tail -20 /tmp/hyperswitch-server.log
            exit 1
        fi
        sleep 3
    done
    
    echo "==> Running BIN routing demo..."
    bash scripts/demo_bin_routing.sh
    
    echo ""
    echo "Server running (PID $(cat /tmp/hs-server.pid)). To stop: kill $(cat /tmp/hs-server.pid)"
}

# Function for the 'test-bin-routing' target
run_tests() {
    cargo test --features v1 -p router bin_routing_tests -- --nocapture
}

# Main Execution Switch
case "$1" in
    demo)
        run_demo
        ;;
    test-bin-routing)
        run_tests
        ;;
    *)
        echo "Usage: $0 {demo|test-bin-routing}"
        exit 1
        ;;
esac