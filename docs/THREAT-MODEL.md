# Threat model

## Protected properties

- A signed call creates at most one vault.
- The quote fixes payer, amount, terms commitment, and deadlines.
- Only the operator can complete a paid call before the deadline.
- Completion transfers only the exact fee to the fixed treasury.
- Refunds and surplus always return to the fixed payer.
- A terminal state cannot be changed or repeated.
- Cross-chain and cross-factory quote replay is rejected.
- The implementation contract cannot be initialized or taken over.

## Covered adversarial cases

The tests cover unauthorized completion, early refund, repeated terminal calls,
tampered quotes, cross-domain replay, counterfactual deposits, expired recovery,
short-credit tokens, blocked recipients, transfer failure, reentrancy attempts,
late payments, surplus, native dust, and multi-vault conservation.

## Out of scope

- Correctness or quality of the offchain service result.
- Compromise of the operator signer or deployment environment.
- USDC issuer pause or blocklist policy.
- Frontend, RPC, facilitator, and wallet security.
- Legal, sanctions, tax, or regulatory compliance.

Use a managed signer or hardware-backed key, monitor every open vault, keep gas
available for settlement, and maintain an independent permissionless-refund
watcher before operating in production.
