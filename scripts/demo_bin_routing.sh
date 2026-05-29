#!/usr/bin/env bash
# demo_bin_routing.sh — end-to-end BIN-based routing demo
#
# Demonstrates that:
#   1. A RuPay card (BIN 508xxx) is routed to Razorpay (domestic acquirer)
#   2. A Visa card  (BIN 411xxx) falls back to Stripe (international)
#   3. The routing decision is visible in logs for every call
#
# Prerequisites: Hyperswitch server running on localhost:8080
#                (docker compose -f docker-compose-demo.yml up -d --wait)

set -euo pipefail

BASE_URL="${HYPERSWITCH_URL:-http://localhost:8080}"
ADMIN_KEY="${ADMIN_API_KEY:-test_admin}"

# Unique run ID so repeated demo runs don't collide in the DB
RUN_ID="$(date +%s)"
DEMO_MERCHANT_ID="demo_bin_${RUN_ID}"

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
RESET="\033[0m"

log()  { printf "${CYAN}[demo]${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}[✓]${RESET} %s\n" "$*"; }
info() { printf "${YELLOW}[→]${RESET} %s\n" "$*"; }

die() { printf "\033[0;31m[✗]${RESET} %s\n" "$*" >&2; exit 1; }

wait_for_server() {
    log "Waiting for Hyperswitch to be ready..."
    for i in $(seq 1 60); do
        if curl -sf "${BASE_URL}/health" >/dev/null 2>&1; then
            ok "Server is up."
            return 0
        fi
        sleep 3
    done
    die "Server did not become ready in time. Check /tmp/hyperswitch-server.log"
}

wait_for_superposition() {
    local sp_url="${SUPERPOSITION_URL:-http://localhost:8081}"
    log "Waiting for Superposition to be ready on ${sp_url}..."
    for i in $(seq 1 20); do
        if curl -sf "${sp_url}/health" >/dev/null 2>&1; then
            ok "Superposition is up."
            return 0
        fi
        sleep 3
    done
    die "Superposition did not become ready. Merchant creation requires it."
}

# ── Step 1: create a merchant account ────────────────────────────────────────
create_merchant() {
    log "Creating merchant account..."
    MERCHANT=$(curl -sf -X POST "${BASE_URL}/accounts" \
        -H "Content-Type: application/json" \
        -H "api-key: ${ADMIN_KEY}" \
        -d "{
            \"merchant_id\": \"${DEMO_MERCHANT_ID}\",
            \"merchant_name\": \"BIN Demo Merchant\"
        }") || die "Failed to create merchant (check server logs for details)"
    MERCHANT_ID=$(echo "$MERCHANT" | grep -o '"merchant_id":"[^"]*"' | cut -d'"' -f4)
    ok "Merchant created: ${MERCHANT_ID}"

    log "Creating API key for merchant..."
    KEY_RESPONSE=$(curl -sf -X POST "${BASE_URL}/api_keys/${MERCHANT_ID}" \
        -H "Content-Type: application/json" \
        -H "api-key: ${ADMIN_KEY}" \
        -d '{"name": "demo key", "description": "BIN routing demo", "expiration": "never"}') \
        || die "Failed to create API key for merchant"
    API_KEY=$(echo "$KEY_RESPONSE" | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
    ok "API key: ${API_KEY}"
}

# ── Step 2: create a business profile ────────────────────────────────────────
create_profile() {
    log "Creating business profile..."
    PROFILE=$(curl -sf -X POST "${BASE_URL}/account/${MERCHANT_ID}/business_profile" \
        -H "Content-Type: application/json" \
        -H "api-key: ${API_KEY}" \
        -d '{"profile_name": "BIN Routing Demo"}') || die "Failed to create profile"
    PROFILE_ID=$(echo "$PROFILE" | grep -o '"profile_id":"[^"]*"' | cut -d'"' -f4)
    ok "Profile: ${PROFILE_ID}"
}

# ── Step 3: register connector accounts (Stripe + Razorpay) ──────────────────
create_connectors() {
    log "Registering connectors (Stripe as international, Razorpay as domestic)..."

    # Stripe — international fallback
    curl -sf -X POST "${BASE_URL}/account/${MERCHANT_ID}/connectors" \
        -H "Content-Type: application/json" \
        -H "api-key: ${API_KEY}" \
        -d '{
            "connector_type": "payment_processor",
            "connector_name": "stripe",
            "profile_id": "'"${PROFILE_ID}"'",
            "connector_account_details": {
                "auth_type": "HeaderKey",
                "api_key": "sk_test_placeholder"
            },
            "payment_methods_enabled": [
                {"payment_method": "card", "payment_method_types": [
                    {"payment_method_type": "credit", "card_networks": ["Visa", "Mastercard"]},
                    {"payment_method_type": "debit",  "card_networks": ["Visa", "Mastercard"]}
                ]}
            ],
            "test_mode": true,
            "disabled": false
        }' >/dev/null && ok "Stripe registered" || info "Stripe registration skipped (may already exist)"

    # Razorpay — domestic RuPay acquirer
    curl -sf -X POST "${BASE_URL}/account/${MERCHANT_ID}/connectors" \
        -H "Content-Type: application/json" \
        -H "api-key: ${API_KEY}" \
        -d '{
            "connector_type": "payment_processor",
            "connector_name": "razorpay",
            "profile_id": "'"${PROFILE_ID}"'",
            "connector_account_details": {
                "auth_type": "BodyKey",
                "api_key": "rzp_test_placeholder",
                "key1": "rzp_test_placeholder"
            },
            "payment_methods_enabled": [
                {"payment_method": "card", "payment_method_types": [
                    {"payment_method_type": "debit", "card_networks": ["RuPay"]}
                ]}
            ],
            "test_mode": true,
            "disabled": false
        }' >/dev/null && ok "Razorpay registered" || info "Razorpay registration skipped (may already exist)"
}

# ── Step 4: create and activate the BIN routing algorithm ────────────────────
setup_routing() {
    log "Creating BIN-based routing algorithm..."

    ROUTING_ALGO=$(curl -sf -X POST "${BASE_URL}/routing" \
        -H "Content-Type: application/json" \
        -H "api-key: ${API_KEY}" \
        -d "{
            \"name\": \"RuPay Domestic Routing\",
            \"description\": \"Route RuPay BINs to Razorpay, everything else to Stripe\",
            \"profile_id\": \"${PROFILE_ID}\",
            \"algorithm\": {
                \"type\": \"bin_based\",
                \"data\": {
                    \"rules\": [
                        {\"prefix\": \"508\", \"label\": \"rupay_domestic\", \"connectors\": [{\"connector\": \"razorpay\"}]},
                        {\"prefix\": \"606\", \"label\": \"rupay_domestic\", \"connectors\": [{\"connector\": \"razorpay\"}]},
                        {\"prefix\": \"607\", \"label\": \"rupay_domestic\", \"connectors\": [{\"connector\": \"razorpay\"}]},
                        {\"prefix\": \"608\", \"label\": \"rupay_domestic\", \"connectors\": [{\"connector\": \"razorpay\"}]},
                        {\"prefix\": \"609\", \"label\": \"rupay_domestic\", \"connectors\": [{\"connector\": \"razorpay\"}]},
                        {\"prefix\": \"652\", \"label\": \"rupay_domestic\", \"connectors\": [{\"connector\": \"razorpay\"}]},
                        {\"prefix\": \"817\", \"label\": \"rupay_domestic\", \"connectors\": [{\"connector\": \"razorpay\"}]}
                    ],
                    \"fallback\": [{\"connector\": \"stripe\"}]
                }
            }
        }") || die "Failed to create routing algorithm"

    ALGO_ID=$(echo "$ROUTING_ALGO" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    ok "Routing algorithm created: ${ALGO_ID}"

    log "Activating routing algorithm on profile..."
    curl -sf -X POST "${BASE_URL}/routing/${ALGO_ID}/activate" \
        -H "Content-Type: application/json" \
        -H "api-key: ${API_KEY}" \
        -d '{}' >/dev/null && ok "Algorithm activated" || die "Failed to activate algorithm"
}

# ── Step 5: fire test payments ────────────────────────────────────────────────
fire_payment() {
    local label="$1"
    local card_number="$2"

    info "Firing payment: ${label} (card: ${card_number:0:6}xxxxxx)"

    RESPONSE=$(curl -sf -X POST "${BASE_URL}/payments" \
        -H "Content-Type: application/json" \
        -H "api-key: ${API_KEY}" \
        -d '{
            "amount": 1000,
            "currency": "INR",
            "confirm": true,
            "payment_method": "card",
            "payment_method_data": {
                "card": {
                    "card_number": "'"${card_number}"'",
                    "card_exp_month": "12",
                    "card_exp_year": "2030",
                    "card_holder_name": "Test User",
                    "card_cvc": "123"
                }
            },
            "profile_id": "'"${PROFILE_ID}"'"
        }') 2>/dev/null || RESPONSE="{}"

    PAYMENT_ID=$(echo "$RESPONSE" | grep -o '"payment_id":"[^"]*"' | cut -d'"' -f4) || true
    ok "${label} → payment_id: ${PAYMENT_ID:-<check logs>}"
}

demo_payments() {
    printf "\n${BOLD}=== BIN Routing Demo ===${RESET}\n"
    printf "Watch the server logs for structured bin_routing_decision log lines:\n"
    printf "  docker compose -f docker-compose-demo.yml logs -f hyperswitch-server | grep bin_routing\n\n"

    # RuPay BINs → should route to Razorpay (Luhn-valid test numbers)
    fire_payment "RuPay (508xxx) → Razorpay" "5089300000000007"
    fire_payment "RuPay (606xxx) → Razorpay" "6069000000000005"
    fire_payment "RuPay (652xxx) → Razorpay" "6521000000000007"

    # International BINs → should fallback to Stripe
    fire_payment "Visa  (424xxx) → Stripe  " "4242424242424242"
    fire_payment "Visa  (411xxx) → Stripe  " "4111111111111111"

    printf "\n${BOLD}Expected log output (from server):${RESET}\n"
    cat <<'LOG'
  bin_routing_decision="rule_matched"  card_bin="508930" rule_label="rupay_domestic" chosen_connector="razorpay"
  bin_routing_decision="rule_matched"  card_bin="606900" rule_label="rupay_domestic" chosen_connector="razorpay"
  bin_routing_decision="no_match_fallback" card_bin="411111" fallback_connector="stripe"
LOG
}

# ── Seed RuPay BIN table so card_network is auto-detected ────────────────────
seed_bin_table() {
    log "Seeding RuPay BIN table (cards_info)..."
    python3 -c "
import datetime; now = datetime.datetime.utcnow().isoformat()
prefixes = ['508','606','607','608','609','652','817']
rows = [f\"('{p}{i:03d}','RuPay','RuPay','DEBIT','CONSUMER','IN','{now}','{now}')\" for p in prefixes for i in range(1000)]
sql = 'INSERT INTO cards_info (card_iin,card_issuer,card_network,card_type,card_subtype,card_issuing_country,date_created,last_updated) VALUES ' + ','.join(rows) + ' ON CONFLICT (card_iin) DO NOTHING;'
open('/tmp/rupay_bins.sql','w').write(sql)
" && PGPASSWORD=db_pass psql -h localhost -U db_user -d hyperswitch_db \
    -f /tmp/rupay_bins.sql >/dev/null 2>&1 \
    && ok "7000 RuPay BIN entries seeded" \
    || info "BIN seeding skipped (psql not available)"
}

# ── Main ──────────────────────────────────────────────────────────────────────
wait_for_server
wait_for_superposition
create_merchant
create_profile
create_connectors
setup_routing
seed_bin_table
demo_payments

printf "\n${GREEN}${BOLD}Demo complete.${RESET}\n"
printf "Check routing decisions in server logs:\n"
printf "  docker compose -f docker-compose-demo.yml logs hyperswitch-server | grep bin_routing\n\n"
