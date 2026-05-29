# BIN-Based Routing — Session Notes

## What Was Built

Added BIN-prefix routing as a new `StaticRoutingAlgorithm` variant to Hyperswitch.
Routes Indian RuPay cards (BIN prefixes 508, 606, 607, 608, 609, 652, 817) to a domestic
acquirer (Razorpay); all other cards fall back to an international acquirer (Stripe).

## Files Changed

### Core Routing Logic
- `crates/api_models/src/routing.rs` — Added `BinRule`, `BinBasedRoutingConfig`, `BinBased` variant
- `crates/router/src/core/payments/routing.rs` — `CachedAlgorithm::BinBased`, `perform_bin_routing()`, unit tests
- `crates/router/src/core/routing.rs` — Skip arms for BinBased in decision-engine migration blocks
- `crates/router/src/core/routing/helpers.rs` — Connector validation for BinBased
- `crates/router/src/core/routing/transformers.rs` — `BinBased → StorageAdvanced` (avoids DB migration)
- `crates/router/src/types/api/routing.rs` — Re-exports for BinBasedRoutingConfig, BinRule

### Razorpay Connector (card support added for demo)
- `crates/hyperswitch_connectors/src/connectors/razorpay.rs` — Added Card (credit/debit) to `RAZORPAY_SUPPORTED_PAYMENT_METHODS`
- `crates/hyperswitch_connectors/src/connectors/razorpay/transformers.rs` — Added `RazorpayCardDetails`, Card arm in TryFrom, card URL in get_url

### Demo Infrastructure
- `docker-compose-demo.yml` — Postgres, Redis, Superposition, migration_runner
- `Makefile` — `demo` and `test-bin-routing` targets
- `scripts/demo_bin_routing.sh` — End-to-end demo: merchant → profile → connectors → BIN routing → test payments
- `DECISIONS.md` — Design rationale

## Key Design Decisions

| Decision | Reason |
|----------|--------|
| `RoutingAlgorithmKind::BinBased` maps to storage `Advanced` | Avoids DB migration; Euclid DSL also uses `Advanced` |
| Longest-prefix match | Same semantics as IP routing tables; more specific rules win |
| BIN table (`cards_info`) for auto-detection | Card network detected automatically from card number; no manual `card_network` field needed in request |
| `perform_bin_routing()` returns fallback on no match | Never panics; graceful degradation |

## Architecture

```
POST /payments (card_number: 6088150000000005)
  │
  ├─ BIN lookup: cards_info table → card_network = "RuPay"
  │
  ├─ refresh_routing_cache_v1
  │   └─ StaticRoutingAlgorithm::BinBased(config) → CachedAlgorithm::BinBased(config)
  │
  ├─ static_routing_v1 / perform_static_routing_v1
  │   └─ perform_bin_routing(config, card_bin="608815")
  │       ├─ finds prefix "608" → rule_matched
  │       └─ returns [razorpay]
  │
  └─ connector eligibility check → razorpay selected
      └─ Razorpay API called (fails with test creds — expected)
```

## Structured Log Output (proof of routing)

```json
{
  "message": "bin_routing: matched BIN prefix rule",
  "bin_routing_decision": "rule_matched",
  "card_bin": "608815",
  "rule_prefix": "608",
  "rule_label": "rupay",
  "chosen_connector": "razorpay"
}
```

## Running Tests

```bash
# Unit tests (no server needed)
make test-bin-routing

# End-to-end demo
make demo
```

## Recurring Issues & Fixes

### API key invalid after restart
Every `make demo` wipes the DB (--volumes). Run this to get fresh credentials:
```bash
M=$(PGPASSWORD=db_pass psql -h localhost -U db_user -d hyperswitch_db -t -c \
  "SELECT merchant_id FROM merchant_account ORDER BY created_at DESC LIMIT 1;" 2>/dev/null | tr -d ' \n')
P=$(PGPASSWORD=db_pass psql -h localhost -U db_user -d hyperswitch_db -t -c \
  "SELECT id FROM business_profile WHERE merchant_id='$M' ORDER BY created_at DESC LIMIT 1;" 2>/dev/null | tr -d ' \n')
K=$(curl -s -X POST http://localhost:8080/api_keys/$M \
  -H "Content-Type: application/json" -H "api-key: test_admin" \
  -d '{"name":"k","description":"k","expiration":"never"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))")
echo "API_KEY=$K  PROFILE=$P"
```

### RuPay cards routing to Stripe
Two causes — both must be fixed after every `make demo`:
1. `cards_info` table is empty → BIN lookup returns null network → Razorpay eligibility fails
2. Routing algorithm only has 508/606/652/817, not 608
Fix: run `.claude/setup-after-demo.sh`

### Superposition "Config version not found"
Run the Superposition init before starting the server:
```bash
curl -sf -X POST http://localhost:8081/dimension \
  -H "Content-Type: application/json" -H "Authorization: Bearer 123456" \
  -H "x-org-id: localorg" -H "x-tenant: dev" \
  -d '{"dimension":"processor_merchant_id","priority":10,"position":1,"description":"Hyperswitch merchant ID","schema":{"type":"string"},"function_name":null,"change_reason":"init"}' 2>/dev/null || true

curl -sf -X POST http://localhost:8081/default-config \
  -H "Content-Type: application/json" -H "Authorization: Bearer 123456" \
  -H "x-org-id: localorg" -H "x-tenant: dev" \
  -d '{"key":"fingerprint_secret","value":"","schema":{"type":"string"},"function_name":null,"change_reason":"init","description":"Merchant fingerprint secret"}' 2>/dev/null || true
```
