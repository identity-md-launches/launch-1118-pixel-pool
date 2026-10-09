# PIXEL test coverage

Run the complete suite with `forge build` and `forge test`. To keep generated
artifacts inside the assignment's scratch space:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache -vv
```

The existing `PixelPoolHook.t.sol` integration tests run the real v4 PoolManager
with IMD on either side of PIXEL. They cover the permission mask, initialization
restrictions, unauthorized callbacks, shade boundaries, exact-input/output and
partial fills, packed rows, repainting, event attribution, failed settlement,
absence of hook fees, and SVG content and render gas. `PixelToken.t.sol` covers
the fixed supply and token transfer/approval edge cases.

The additional stateful suites are:

- `PixelToken.invariant.t.sol`: 256 sequences of 128 calls across four holders.
  Transfers, approvals, revocations, delegated transfers, self-transfers, and
  rejected calls are interleaved. An independent ledger checks every holder's
  balance and every owner/spender allowance after each action, and their balances
  must sum to the fixed `10^27` supply. Explicit sequences pin full-balance moves,
  infinite approvals, and rollback after allowance spending fails. Revocation
  also has a 1,000-case fuzz test.
- `PixelPoolHook.invariant.t.sol`: 128 sequences of 64 actions in **each** currency
  ordering. Successful swaps and liquidity changes execute through a real
  PoolManager and the existing settlement router. A separate hookless pool with
  the same 12,500 LP fee receives identical operations; swap deltas and pool state
  must agree throughout each sequence. The model records one unpacked byte per
  committed swap and compares the entire packed canvas after every action.
  Events, stroke count, pool binding, token conservation, zero hook claims and
  zero unsettled deltas are also checked. Invalid callbacks and failed settlement
  must leave this model unchanged. Every campaign ends by withdrawing all
  liquidity and fees. A deterministic 1,056-swap mixed sequence exercises the
  repaint boundary, and unsolicited token deposits must remain untouched by swaps.

Both handlers explicitly restrict fuzz targets and enable `fail-on-revert`.
Expected failures are asserted inside the handlers; unexpected reverts fail the
campaign. Bounds preserve funded, tradable pools; the pre-existing callback fuzz
tests additionally cover the full signed 128-bit delta domain.

All tests run offline using dependencies already in the repository. IMD is the
existing ERC20 test double installed at the specified mainnet address; this suite
does not verify live IMD behavior or current Ethereum state. The invariant hook's
actual constructor runs at a permission-bearing test address; the original suite
separately covers CREATE2 deployment and constructor permission validation.
