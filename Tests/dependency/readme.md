# Token consumer checks

This package imports `talus::us::US` and uses `Coin<US>`. It depends on the
local token package so CI can check the source in the current pull request.

From the repository root, use Sui 1.80.0 and Python 3.11 or newer:

```sh
just test-dependency mainnet
just test-dependency testnet
```

Each check builds the consumer, verifies its dependency address and token type,
and rejects a token address from the other network. The expected deployments
are checked against `talus/Published.toml`. The checks compile without submitting
transactions or requiring a funded wallet.

To reproduce the deployed token module, use the Sui 1.59.1 binary:

```sh
python3 Tests/dependency/verify.py --sui /path/to/sui bytecode
```

This compiles the current token sources in a temporary directory and compares
the module SHA256 with the bytes from the Mainnet and Testnet publications.
The compiler uses its pinned framework dependencies. The repository's current
lockfile remains intact. The expected hash and publication transaction digests
are recorded in `verify.py`.

These checks use a local dependency. See the [token README](../../talus/README.md)
for the MVR dependency used by applications.
