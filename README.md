# PIXEL POOL

An immutable ERC-20 and Uniswap v4 hook for the PIXEL/IMD launch on Ethereum mainnet.
Every successful `afterSwap` callback paints the next dot of a 32×32 on-chain canvas.
The hook takes no fee, returns no delta, and makes no external calls or fund transfers.
The pool's static LP fee is **12500 (1.25%)**.

## Build and check

Install Foundry and Solidity 0.8.26, then run:

```sh
forge build
forge test
forge fmt --check
```

The compiler is pinned in `foundry.toml`; the EVM target is Cancun, optimizer runs are 200,
and `bytecode_hash = "none"`. No FFI, filesystem permissions, RPC, environment variables,
or dependency downloads are needed by the tests. All dependency sources and their licenses
are ordinary files in `lib/`; see [DEPENDENCIES.md](DEPENDENCIES.md). There are no submodules.

## Contracts

`src/PixelToken.sol` implements a plain ERC-20 with no constructor arguments. Its name is
`Pixel Pool`, symbol `PIXEL`, decimals 18, and constant supply `10^27` minor units
(1,000,000,000 PIXEL). The constructor assigns the entire supply to its caller, which will
be the launch factory. Transfers and allowances follow ordinary ERC-20 behavior, including
zero-value transfers, self-transfers, and unlimited allowances. Transfers to zero revert.
There is no mint, burn, tax, owner, pause, permit, proxy, or upgrade interface.

`src/PixelPoolHook.sol` implements `IHooks` directly and imports only v4-core. Its constructor
is `PixelPoolHook(IPoolManager manager, address token)` in that order. Both arguments must
already have code, and `token` must differ from IMD. These bindings are immutable.
`Hooks.validateHookPermissions` enforces exactly `beforeInitialize` and `afterSwap`;
the lower 14 address bits must equal `0x2040`.

`beforeInitialize` requires the bound PoolManager as caller and permits one successful
initialization. It validates the sorted launch-token/IMD pair, this hook, fee 12500 and
tick spacing 60, then records the full `poolId` and `quoteIsCurrency0`. A failed manager
initialization rolls back this lock. The initializer's address and opening price are not
restricted by the hook; atomic factory deployment and initialization are required below.

`afterSwap` requires the bound manager and the recorded full pool key. It increments
`strokes`, then updates pixel `(strokes - 1) % 1024`. Pixels run left to right, top to bottom.
Pixel 1023 is followed by pixel 0; repainting overwrites only the visited byte, leaving the
rest of the previous pass visible. Initialization and liquidity changes do not paint.
Disabled callbacks always revert.

The buy direction is `zeroForOne == quoteIsCurrency0`: IMD in and PIXEL out. Shading uses
the absolute IMD component of the actual `BalanceDelta`, including any fee reflected in
that component. It does not use the requested amount. This works with either currency
ordering, exact input, exact output, and partial fills. A successful callback with zero
delta still paints the darkest color for its direction. Reverted swaps do not persist paint.

| Absolute IMD amount (18 decimals) | Buy index / color | Sell index / color |
| --- | --- | --- |
| `< 5` | 1 / `#1f7a3d` | 5 / `#7a1f1f` |
| `>= 5`, `< 50` | 2 / `#22b455` | 6 / `#c42b2b` |
| `>= 50`, `< 500` | 3 / `#2ee66b` | 7 / `#ff3b3b` |
| `>= 500` | 4 / `#8dffad` | 8 / `#ff9a9a` |

Index 0 is empty, `#0b0b12`. Each of the 32 `uint256` rows stores 32 one-byte palette
indexes; its leftmost dot is the least significant byte. `canvas()` returns all rows,
`pixelAt(i)` returns one index (reverting for `i >= 1024`), and `strokes()` counts all passes.
`quoteIsCurrency0()` is meaningful after initialization. `render()` returns a standalone
320×320 SVG with 1024 circles and a dark background, constructed in one preallocated output
buffer. No renderer, metadata service, or keeper is required.

`Painted(uint256 indexed stroke, uint256 indexed pixel, uint8 color, address indexed painter)`
records `tx.origin` as requested. This is attribution only, never authorization. With
relayers or account abstraction it can identify a relayer/bundler rather than the trader;
it does not confer ownership of a dot or any rights.

## Deployment parameters and responsibilities

The exact requested [launch.json](launch.json) is included. The launch system resolves
`$poolManager` and `$token`; neither is a guessed deployment address. The only fixed pair
address is the supplied IMD address, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`.
There is no owner or recipient parameter.

The launch operator/factory must:

1. Verify the Ethereum mainnet chain, the intended canonical v4 PoolManager and IMD's code,
   transfer behavior, and 18-decimal units. Supply that manager as the constructor argument.
2. Deploy `PixelToken` first. Its full supply belongs to the factory; allocations and liquidity
   funding are responsibilities of the launch system, outside these two contracts.
3. Mine a CREATE2 salt using the actual CREATE2 deployer address, the final hook creation
   bytecode, and `abi.encode(manager, token)`. The predicted address must satisfy
   `uint160(predicted) & 0x3fff == 0x2040`, with no other permission bits. The formula is
   `last20(keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode)))`. Re-mine when any
   constructor argument, deployer, compiler setting, or bytecode changes. The tests include
   an executable Solidity example that deploys the real hook at a mined address.
4. **Deploy the hook and initialize its pool in the same transaction.** Sort PIXEL and IMD
   numerically into `currency0`/`currency1`, use this hook, fee 12500 and tick spacing 60.
   Do not leave a deployed hook uninitialized: the first valid initialization is permissionless
   and fixes the pool's price. Before deployment, the enabled initialization callback causes
   attempts to initialize the predicted hook address without code to revert.
5. Set the actual opening `sqrtPriceX96` from the launch economics with the sorted currency
   order accounted for. The manifest's `79228162514264337593543950336` is `2^96` for provenance;
   the hook intentionally does not require a 1:1 launch price. Seed liquidity through the
   launch system and rehearse initialization, buys, sells, and withdrawals on a recent fork.
6. Verify both contracts' source/constructor arguments and the mined permissions, confirm
   `poolId`, `quoteIsCurrency0`, token supply, and pool parameters after launch, and monitor
   pool and `Painted` events as needed.

There are **no after-launch settings or administrative calls**. Nobody can reset the canvas,
change the pair, redirect a fee, pause, upgrade, or rescue assets. Do not send assets to the
hook; it provides no withdrawal mechanism. Routers and liquidity providers remain responsible
for normal v4 settlement and swap slippage limits. The hook is a deterministic visual record,
not randomness or an oracle: transaction ordering and deliberate trading determine the canvas.

## Verification performed

The delivered tests deploy a real vendored `PoolManager`, real `PixelToken` contracts on
both sides of IMD in the address ordering, and CREATE2-mined hooks. A local standard ERC-20
test double is installed at IMD's specified address; these are local integration tests, not
a claim that mainnet IMD behavior was verified.

Coverage includes ordered packing across rows; all exact shade thresholds in both directions;
all four direction/exactness combinations; partial fills; two full passes and a third-pass
start; event topics and origin attribution; one-pool binding; disabled and unauthorized
callbacks; invalid constructor and initialization inputs; initialization without code;
rollback on initialization/settlement failure; empty-pool zero deltas; signed-delta extremes;
liquidity withdrawal; zero hook balances/claims/deltas; ERC-20 allowances and conservation;
and runtime/admin-selector checks matching the supplied baseline's intent.

Fuzz tests compare actual swap amounts against an otherwise identical pool with no hook,
exercise arbitrary signed deltas and directions, enforce pixel bounds, and check token
conservation. Each fuzz test runs 256 cases by default. Full SVG checks compare all 1024
coordinates and colors, including empty dots. With the pinned compiler/settings, the
full-canvas cold render call measured **3,736,413 gas**, below the 15,000,000 limit, in both
currency orderings. Hook runtime is 5,322 bytes; token runtime is 1,356 bytes.

The implementation review used the supplied Ethereum and v4 security references: caller
and pool checks precede mutations; permissions have no return-delta flags; callbacks return
zero hook delta; quote negation widens to int256 first; painting has no external calls;
render loops and memory writes are bounded; and no privileged execution paths exist.
No live transactions, mainnet fork rehearsal, Slither/Mythril, or independent external audit
were performed. Mainnet rehearsal and independent review remain deployment responsibilities.
