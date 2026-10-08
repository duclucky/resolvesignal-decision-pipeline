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
  /v2/requests/{call_id}/pay:
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

An unpaid `POST /v2/requests/{call_id}/pay` must return status `402` and a base64-encoded
`PAYMENT-REQUIRED` header whose decoded x402 v2 object contains a non-empty
`accepts[]`. Each accepted requirement declares the amount, network, asset, and
seller destination. A successful paid response returns status `200` with a
payment receipt and the checked decision result.

The runtime accepts standard x402 v2 `exact` on Arc Mainnet (`eip155:5042`).
Each admitted request receives an initialized per-call escrow vault, which is
the seller destination in that call's challenge.

## Live ResolveSignal reference

- Quote intake: `POST https://resolvesignal.com/v2/requests`
- Paid resource: `POST https://resolvesignal.com/v2/requests/{call_id}/pay`
- OpenAPI document: <https://resolvesignal.com/openapi.json>
- Human and agent integration guide: <https://resolvesignal.com/integrate>
- Price: 0.06 USDC per call
- Accepted network: Arc Mainnet (`eip155:5042`)

The live challenge and OpenAPI document are authoritative. Do not infer extra
networks or payment rails from unrelated Circle products.
