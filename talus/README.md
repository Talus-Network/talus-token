# Talus Token

This package defines the Talus Network US coin on Sui, registered in MVR as
`@talus/token`. Its Move type is `talus::us::US`. It has 9 decimals, so one US
equals 1,000,000,000 base units.

Initialization minted 10,000,000,000 US. Holders can burn their coins, reducing
total supply. The TreasuryCap is stored under the shared ProtectedTreasury
object, and CoinMetadata is frozen.

## Deployments

Both deployments are package version 1.

| Network | Package ID |
| --- | --- |
| Mainnet | `0xee962a61432231c2ede6946515beb02290cb516ad087bb06a731e922b2a5f57a` |
| Testnet | `0x5f1861ac8198fae5dc6ec79e435d653d08167187ad8c0522c34f34c372853c5a` |

The canonical coin type is the corresponding package ID followed by
`::us::US`.

| Network | ProtectedTreasury ID |
| --- | --- |
| Mainnet | `0x0cd722966d36096902ae3de036c6901b142af151e0d375b0f2adf94b786c177a` |
| Testnet | `0xbc99a0672ffeb94ebde580c7e17fdb936030a5f759d7448b32ac47479f0a5851` |

Use the package and treasury from the same network.

## Public interface

```move
public fun total_supply(treasury: &ProtectedTreasury): u64
public fun burn(treasury: &mut ProtectedTreasury, coin: Coin<US>)
```

`total_supply` returns the current supply in base units. `burn` consumes a
`Coin<US>` and reduces supply by its value. It does not return the coin.

## Use through MVR

Add the version 1 dependency to your package's `Move.toml`:

```toml
[dependencies]
talus = { r.mvr = "@talus/token/1" }
```

Import the coin type with:

```move
use sui::coin::Coin;
use talus::us::US;
```

The MVR version suffix selects onchain package version 1. Build for Mainnet or
Testnet to select the corresponding deployment.

## Build and test

From this directory, build and test with Sui 1.80.0:

```sh
sui move build -e mainnet
sui move test -e mainnet
```

To reproduce the deployed module with Sui 1.59.1, follow the
[bytecode verification instructions](../Tests/dependency/readme.md).

## Audit, license, and contact

The repository includes a [token audit report](audit/talus-zenith-2025-11-10.pdf).
Consult the report for its reviewed revision, scope, and findings.

The package is distributed under [Apache License 2.0](../LICENSE).

Project: [Talus Network](https://talus.network). Contact: `hi@talus.network`.
