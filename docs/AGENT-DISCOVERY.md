# Agent discovery and x402 runtime proof

An agent-facing API needs both static discovery metadata and a real HTTP 402
challenge. Keep the OpenAPI price equal to the middleware price.

## OpenAPI fields

Add concise agent guidance, a human contact, usage documentation, and payment
metadata to every paid operation:

```yaml
info:
  title: ResolveSignal-compatible decision service
  version: 1.0.0
  contact:
    email: support@example.com
  x-guidance: >-
    Submit a complete typed decision request when an agent must choose one
    caller-authorized action from current evidence. The service returns one
    checked action with fixed parameters and measurable success criteria.
servers:
  - url: https://api.example.com
    description: Public API
externalDocs:
  url: https://api.example.com/docs
paths:
  /v2/resolve:
    post:
      x-payment-info:
        price:
          mode: fixed
          currency: USDC
          amount: "0.060000"
        protocols:
          - x402: {}
      responses:
        "200":
          description: Checked decision and payment receipt
        "402":
          description: An x402 payment is required
          headers:
            PAYMENT-REQUIRED:
              schema:
                type: string
```

`x-guidance` should state the input, output, and correct time to call the API.
Do not put credentials, internal URLs, wallet keys, or production topology in
the specification.

## Runtime proof

An unpaid `POST /v2/resolve` must return status `402` and a base64-encoded
`PAYMENT-REQUIRED` header whose decoded x402 v2 object contains a non-empty
`accepts[]`. Each accepted requirement declares the amount, network, asset, and
seller destination. A successful paid response returns status `200` and the
middleware's `PAYMENT-RESPONSE` receipt header.

The reference adapter configures the official middleware to accept only Arc
Mainnet (`eip155:5042`). Its unpaid challenge must contain exactly that network.

## Live ResolveSignal reference

- Paid route: `POST https://resolvesignal.com/v2/resolve`
- OpenAPI document: <https://resolvesignal.com/openapi.json>
- Human and agent integration guide: <https://resolvesignal.com/integrate>
- Price: 0.06 USDC per call
- Accepted network: Arc Mainnet (`eip155:5042`)

The live challenge and OpenAPI document are authoritative. Do not infer extra
networks from the Circle Gateway product's general chain support.

## Reference adapter

See [`adapters/circle-gateway/`](../adapters/circle-gateway/) for a minimal
seller process. It exposes only `/livez` and the paid `/v2/resolve` route, calls
an authenticated decision service to prepare a checked result before
settlement, and contains no deployment address or secret.
