# x402 integration

This primitive complements standard x402 v2 `exact` payment. It does not replace
the HTTP 402 negotiation or require a custom buyer signature format.

## Seller flow

1. Validate the request before creating a payment challenge.
2. Create a random `callId` and an opaque `termsHash`. The hash should commit to
   the request, service version, price, delivery policy, and refund policy without
   publishing the request itself.
3. Construct and sign an `ExactEscrowFactory.Quote` using EIP-712 domain
   `ExactEscrowFactory`, version `3`, chain ID `5042`, and the factory address.
4. Call `predictVault`, then `createVault`. Both return the same per-call address.
5. Advertise that vault as the x402 `payTo` recipient. Require Arc Mainnet
   `eip155:5042`, USDC `0x3600000000000000000000000000000000000000`,
   and the quote's exact amount.
6. After settlement, verify the canonical transaction receipt: chain, token,
   payer, recipient, amount, success, and quote binding. A vault balance by itself
   is not proof of who paid.
7. Deliver the response. If it passes the seller's quality gate, call `complete`
   with a salted result commitment. Otherwise call `refund`.
8. Reconcile every ambiguous transaction by hash. Never issue a second payment
   challenge automatically for the same call.

## Buyer flow

A standard x402 exact client reviews the 402 challenge and signs one USDC
authorization to the advertised vault. The buyer does not sign a contract-specific
payment message. The operator-signed quote creates and binds the vault.

## Recovery

- Before `completeBy`, the operator can refund.
- At or after `completeBy`, anyone can call `refund`.
- After either terminal state, anyone can call `returnSurplus`; funds can only go
  to the original payer.
- Never send funds to the factory or implementation. They are not payment
  recipients and have no sweep function.
