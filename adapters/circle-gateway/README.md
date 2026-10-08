# Circle Gateway x402 seller adapter

This minimal Node 22 service adds Circle Gateway payments to a decision endpoint.
It exposes only `GET /livez` and paid `POST /v2/resolve`. The official
`@circle-fin/x402-batching` middleware returns the unpaid HTTP 402 challenge and
accepts only Arc Mainnet (`eip155:5042`).

The adapter prepares a checked decision through an authenticated upstream call
inside `onBeforeSettle`. If preparation fails, settlement is aborted and no
service fee is settled; this is distinct from charging and later refunding the
caller. No partial model output is returned. Successful responses include the
middleware payment receipt fields.

## Configure

Copy `.env.example` to an ignored environment source and set:

- `SELLER_ADDRESS`: non-zero EVM address controlled by the seller;
- `UPSTREAM_DECISION_URL`: full private URL that prepares one checked result;
- `UPSTREAM_BEARER_TOKEN`: 32-256 character shared secret;
- `PRICE_USDC`: exact decimal price, default `0.06`;
- `HOST` and `PORT`: listen address and port;
- `GATEWAY_FACILITATOR_URL`: optional credential-free HTTPS facilitator URL.

The upstream must accept the request JSON and return a successful JSON object
containing `decision`. Keep it private or require the shared bearer token so a
caller cannot bypass payment.

```bash
npm ci
npm test
npm start
```

Put a TLS reverse proxy in front of the service. Keep the default loopback
listen address when the proxy runs on the same host. Never commit seller keys,
wallet sessions, shared tokens, production hostnames, or customer payloads.

This adapter uses Gateway settlement and does not recreate the delivery-aware
release/refund semantics of the Arc vault contracts in `src/`.
