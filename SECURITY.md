# Security policy

## Scope

Reports are accepted for the intake contracts, compiler, model boundaries,
source-binding checks, deterministic renderer, workflow state machine,
`ExactEscrowFactory`, `ExactPaymentVault`, deployment manifest, and documented
x402 integration pattern.

Do not test the production deployment with funds or customer data. Do not send
USDC to the factory or implementation; only a vault bound to a verified signed
quote is a payment recipient.

## Reporting

Report vulnerabilities privately to **Support@resolvesignal.com**. Include the
affected commit, impact, reproduction steps, and a minimal proof of concept. Do
not open a public issue for an unpatched vulnerability and never send secrets or
real customer payloads.

## Status

The code has structural, semantic-gate, concurrency, refund, unit, fuzz,
regression, and stateful invariant coverage. It has not received an independent
professional audit and is provided without warranty under the MIT License.
