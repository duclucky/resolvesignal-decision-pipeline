# Security policy

## Scope

Security reports are accepted for `ExactEscrowFactory`, `ExactPaymentVault`, the
deployment manifest, and the documented x402 integration pattern in this
repository.

Do not test against the production deployment with funds you cannot afford to
lose. Do not send USDC directly to the factory or implementation. Only a vault
bound to a signed quote is a valid payment destination.

## Reporting

Report vulnerabilities privately to **Support@resolvesignal.com**. Include the
affected commit, impact, reproduction steps, and a minimal proof of concept.
Do not open a public issue for an unpatched vulnerability.

## Status

The contracts have unit, fuzz, regression, and stateful invariant coverage.
They have not received an independent professional audit. This repository is
reference infrastructure and is provided without warranty under the MIT License.
