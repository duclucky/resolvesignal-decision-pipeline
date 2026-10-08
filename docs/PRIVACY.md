# Privacy and retention

ResolveSignal is designed as a stateless pay-per-call service from the caller's
perspective. A request exists only for validation, payment binding, processing,
delivery, and terminal reconciliation.

## Sensitive context

While a call is active, its isolated context may contain the normalized request,
compiled contract, input commitment, typed model output, checked result, and
payment locator. Context is indexed by call ID and is never shared between calls.

After completion or confirmed refund, the public workflow deletes the request and
result objects. A minimal terminal receipt may retain:

- call ID and status;
- payer and public quote metadata;
- payment/settlement transaction identifiers; and
- a non-sensitive failure code.

It does not retain the customer payload, model prompt, model response body, or
returned result.

## Logging

Production operators should log stage codes, latency, provider model names,
transaction IDs, and safe schema paths. Do not log request bodies, authorization
headers, wallet credentials, raw x402 signatures, API keys, or model payloads.

## Onchain data

Only public addresses, value, deadlines, and opaque commitments are placed
onchain. Never put raw business input or output in a quote or transaction.
