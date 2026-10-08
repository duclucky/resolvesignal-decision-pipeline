# Payment lifecycle

The public workflow uses a `PaymentAdapter`; the Arc implementation uses one
deterministic vault per call and standard x402 v2 `exact` payment.

## Seller sequence

1. Validate and normalize the complete request.
2. Compile candidates and run Jev admission at the operator's cost.
3. Bind `callId`, payer, amount, input/terms commitment, quote expiry, and
   delivery deadline in the operator-signed quote.
4. Create or predict the vault and advertise it as x402 `payTo`.
5. Verify chain, token, payer, recipient, amount, transaction success, and call
   binding. A vault balance alone is not payer proof.
6. Run one GPT-5.4 planning and checking sequence.
7. Send the checked response body.
8. On confirmed delivery, commit the result hash and complete the exact fee.
9. On paid processing, quality, timeout, or delivery failure, refund the payer.
10. Purge the input and result context after a terminal receipt is recorded.

## Idempotency

One request key maps to one call. Concurrent submissions using the same key and
payer share the same in-flight quote. Reusing the key with another payer fails.
A terminal key is not automatically reopened or charged again.

## Recovery

- Before `completeBy`, the operator can refund.
- At or after `completeBy`, anyone can call `refund`; funds still return only to
  the bound payer.
- Late or excess USDC can only be returned to the bound payer.
- An unknown settlement is reconciled by transaction identity before any new
  financial action.

The factory and implementation contracts are not payment recipients.
