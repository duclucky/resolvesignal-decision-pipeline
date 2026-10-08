# Architecture

## Components

`ExactEscrowFactory` verifies an operator-signed EIP-712 quote and deploys one
deterministic minimal-proxy vault for its `callId`. A quote binds the payer,
amount, opaque terms commitment, quote expiry, and delivery deadline.

`ExactPaymentVault` is immutable after initialization. It accepts one exact
USDC payment destination and reaches one terminal state:

```text
                         operator + result commitment
                       ┌──────────────────────────────> Completed ──> treasury
signed quote ─> Open ──┤
                       └──────────────────────────────> Refunded ───> payer
                         operator early, anyone after deadline
```

Late or excess ERC-20 USDC can only be returned to the quote's fixed payer.
Sub-atomic native-USDC dust is handled separately because Arc exposes one USDC
pool through native and ERC-20 interfaces with different decimal views.

## Trust boundaries

- The service controls the operator and decides whether a delivered result meets
  its offchain policy. `complete` is an operator attestation, not an onchain proof
  of result quality.
- The payer reviews the quote and authorizes the standard x402 exact payment.
- The contract binds value flow and deadlines. It never receives raw request or
  response content.
- After `completeBy`, refund is permissionless and always targets the bound payer.

## Replay isolation

The quote digest uses EIP-712 domain separation with chain ID and factory
address. A `callId` maps to one digest and one CREATE2 clone. Reusing the same
`callId` with different terms reverts.
