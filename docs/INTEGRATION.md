# Integration

## Decision-only embedding

Install the package with the model adapters:

```bash
python -m pip install -e ".[models]"
```

Construct `DecisionPipeline` with `JevAdmissionClient` and
`OpenAIDecisionClient`. Call `prepare` before payment and `decide` only after the
payment receipt is verified.

## Full paid workflow

Implement the four-operation `PaymentAdapter`:

```python
class PaymentAdapter:
    async def quote(self, *, call_id, payer, input_sha256): ...
    async def verify(self, quote, proof): ...
    async def complete(self, quote, result_sha256): ...
    async def refund(self, quote, reason): ...
```

Pass it to `ResolveSignalWorkflow`. The workflow owns sequencing, idempotency,
per-order locks, the compute semaphore, terminal receipts, and deletion of
sensitive context.

The HTTP layer should expose the machine-readable `form_document()`, return the
quote as an x402 challenge, call `pay_and_process` for a verified payment, and
invoke `Delivery.acknowledge()` only after the response body has been sent. If
the connection fails before delivery, invoke `Delivery.fail()`.

## Arc x402 adapter

For Arc Mainnet require:

- network `eip155:5042`;
- USDC `0x3600000000000000000000000000000000000000`;
- the per-call vault as `payTo`; and
- the exact quoted amount.

Use the ABI and manifest in this repository. Signer custody, RPC selection, and
secret storage are deployment concerns and intentionally remain behind the
adapter interface.

## Caller integration

The caller must retrieve the form, populate every field, retain its request key,
pay at most once, match the returned call ID, and verify fresh authority and
target identity before executing the recommendation. Conditional outcome cases
describe how the caller should interpret later evidence; they are not evidence
that an action already occurred.
