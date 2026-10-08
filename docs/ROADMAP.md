# Roadmap

## Shipped

- Deterministic per-call vaults for standard x402 exact USDC recipients.
- EIP-712 quote binding with EOA and ERC-1271 operator support.
- Exact fee completion, full refund, late-payment recovery, and native dust
  handling for Arc's shared native/ERC-20 USDC pool.
- Unit, fuzz, regression, and stateful invariant coverage.
- Arc Mainnet deployment used by the live ResolveSignal service.

## Next

1. Publish small TypeScript and Python packages for quote construction, receipt
   verification, and refund reconciliation.
2. Add a reference HTTP 402 seller adapter and end-to-end tests against standard
   x402 clients.
3. Add a lightweight event indexer and permissionless refund watcher.
4. Commission an independent professional audit and publish the report.
5. Add deployment verification automation and reproducible bytecode attestations.
6. Collect feedback from independent Arc builders and document production
   integrations without exposing customer payloads.

Roadmap items are plans, not commitments or claims of current functionality.
