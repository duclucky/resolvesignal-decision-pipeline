# Contributing

Issues and pull requests are welcome. Keep changes focused on reusable Arc
payment infrastructure.

Before opening a pull request:

```bash
forge fmt --check
forge build --sizes
forge test -vvv
```

Add a regression test for every behavior change. Never commit wallet material,
private keys, API credentials, customer payloads, production logs, or local
deployment state. Security issues must follow [SECURITY.md](SECURITY.md).
