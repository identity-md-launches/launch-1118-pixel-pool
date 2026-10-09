# Vendored dependencies

All listed source files are copied unchanged from these exact commits. Builds and tests
resolve local remappings only; none of these entries is a git submodule.

| Local path | Upstream pin | Included files | Use |
| --- | --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `src/` except upstream test helpers, and `licenses/` | Hook interfaces/libraries; real PoolManager in local tests |
| `lib/solmate` | [transmissions11/solmate `4b47a19038b798b4a33d9749d25e570443520647`](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `src/auth/Owned.sol`, `LICENSE` | PoolManager's own upstream dependency, only needed for tests |
| `lib/forge-std` | [foundry-rs/forge-std v1.17.0, `f3dae6e6ee381f25eb6a246f7da9b85c91a68219`](https://github.com/foundry-rs/forge-std/tree/f3dae6e6ee381f25eb6a246f7da9b85c91a68219) | `src/` and root license files | Test assertions and cheatcode interface |

The v4-core commit includes `PoolOperation.sol`, as required by the supplied protected tests.
Solmate is pinned to the commit referenced by that v4-core revision. The production hook
uses neither forge-std nor Solmate and has no v4-periphery or OpenZeppelin dependency.
The production token has no imports.

Upstream file headers and licenses are retained. v4-core files use their individually
specified MIT or BUSL-1.1 license; its PoolManager is used locally for testing. Original
project source and tests are MIT licensed. `DEPENDENCY_SHA256SUMS` records every vendored
file so source integrity can be checked offline with `sha256sum -c DEPENDENCY_SHA256SUMS`.
