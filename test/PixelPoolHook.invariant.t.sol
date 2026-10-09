// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PixelPoolHook} from "src/PixelPoolHook.sol";
import {PixelToken} from "src/PixelToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {MockIMD} from "./helpers/MockIMD.sol";

/// @dev The same operations run against a hookless control pool, including fee collection.
/// No manager impersonation is used for successful trades or liquidity operations.
contract PixelPoolSequenceHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    PixelPoolHook public immutable hook;
    PixelToken public immutable token;
    MockIMD public immutable imd;
    PoolRouter public immutable router;
    bool private immutable quote0;
    PoolKey private key;
    PoolKey private control;
    bytes private pixels = new bytes(1024);
    uint256 public successfulSwaps;
    uint256 private cursor;
    int256 public liquidity;

    constructor(IPoolManager manager_, PixelPoolHook hook_, PixelToken token_, PoolKey memory key_) {
        manager = manager_;
        hook = hook_;
        token = token_;
        imd = MockIMD(hook_.IMD());
        key = key_;
        control = key_;
        control.hooks = IHooks(address(0));
        quote0 = Currency.unwrap(key_.currency0) == address(imd);
        router = new PoolRouter(manager_);
        token_.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
    }

    function swap(uint256 rawAmount, bool buy, bool exactInput) public {
        _swap(bound(rawAmount, 1, 1000 ether), buy, exactInput);
    }

    function swapBatch(uint8 rawCount, uint256 rawAmount, bool buy) public {
        uint256 count = bound(rawCount, 1, 8);
        uint256 amount = bound(rawAmount, 1, 1000 ether);
        for (uint256 i; i < count; ++i) {
            _swap(amount, i % 2 == 0 ? buy : !buy, i % 3 == 0);
        }
    }

    function setLiquidity(uint256 rawTarget) public {
        // With 1e24 minimum liquidity and these swap bounds, both directions remain tradable
        // throughout the configured sequence depth. All liquidity is owned by this test router.
        int256 target = int256(bound(rawTarget, 1e24, 1e26));
        router.liquidity(key, target - liquidity);
        router.liquidity(control, target - liquidity);
        liquidity = target;
    }

    function rejectedCallback(uint8 mode, bool buy) public {
        SwapParams memory params = _params(1 ether, buy, true);
        PoolKey memory other = key;
        if (mode % 4 == 0) {
            vm.expectRevert(PixelPoolHook.OnlyPoolManager.selector);
            hook.beforeInitialize(address(manager), key, uint160(2 ** 96));
        } else if (mode % 4 == 1) {
            vm.expectRevert(PixelPoolHook.OnlyPoolManager.selector);
            hook.afterSwap(address(manager), key, params, toBalanceDelta(-1 ether, 1 ether), "");
        } else if (mode % 4 == 2) {
            other.fee = 3000;
            vm.prank(address(manager));
            vm.expectRevert(PixelPoolHook.InvalidPool.selector);
            hook.afterSwap(address(router), other, params, toBalanceDelta(-1 ether, 1 ether), "");
        } else {
            vm.prank(address(manager));
            vm.expectRevert(PixelPoolHook.AlreadyInitialized.selector);
            hook.beforeInitialize(address(router), key, uint160(2 ** 96));
        }
    }

    function revertedSettlement(bool buy) public {
        if (buy) imd.approve(address(router), 0);
        else token.approve(address(router), 0);
        // The hook executes before input settlement fails. Its paint must roll back with the swap.
        (bool ok, bytes memory reason) =
            address(router).call(abi.encodeCall(router.swap, (key, _params(1 ether, buy, true))));
        assertFalse(ok, "swap without an input allowance succeeded");
        bytes memory expected = buy
            ? abi.encodeWithSignature("Panic(uint256)", uint256(0x11))  // MockIMD's allowance subtraction
            : abi.encodeWithSelector(PixelToken.InsufficientAllowance.selector);
        assertEq(reason, expected, "failure must come from input settlement");
        if (buy) imd.approve(address(router), type(uint256).max);
        else token.approve(address(router), type(uint256).max);
    }

    function _params(uint256 amount, bool buy, bool exactInput) private view returns (SwapParams memory) {
        bool zeroForOne = buy == quote0;
        return SwapParams(
            zeroForOne, exactInput ? -int256(amount) : int256(amount), zeroForOne ? uint160(2 ** 95) : uint160(2 ** 97)
        );
    }

    function _swap(uint256 amount, bool buy, bool exactInput) private {
        SwapParams memory params = _params(amount, buy, exactInput);
        vm.recordLogs();
        BalanceDelta actual = router.swap(key, params);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        BalanceDelta referenceDelta = router.swap(control, params);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(referenceDelta), "hook changed trade economics");

        int256 quote = quote0 ? int256(actual.amount0()) : int256(actual.amount1());
        uint256 magnitude = uint256(quote < 0 ? -quote : quote);
        uint8 color = buy ? 1 : 5;
        uint256[3] memory boundaries = [uint256(5 ether), 50 ether, 500 ether];
        for (uint256 i; i < boundaries.length; ++i) {
            if (magnitude >= boundaries[i]) ++color;
        }
        ++successfulSwaps;
        uint256 painted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            ++painted;
            assertEq(logs[i].topics.length, 4);
            assertEq(logs[i].topics[0], keccak256("Painted(uint256,uint256,uint8,address)"));
            assertEq(uint256(logs[i].topics[1]), successfulSwaps);
            assertEq(uint256(logs[i].topics[2]), cursor);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), tx.origin);
            assertEq(abi.decode(logs[i].data, (uint8)), color);
        }
        assertEq(painted, 1, "exactly one Painted event per committed swap");
        pixels[cursor] = bytes1(color);
        assertEq(hook.pixelAt(cursor), color);
        cursor = cursor == 1023 ? 0 : cursor + 1;
    }

    /// @dev Independent unpacked canvas model; every byte, including untouched pixels, is checked.
    function assertState() public view {
        assertEq(hook.strokes(), successfulSwaps, "failed/non-swap actions must not paint");
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()), "pool lock changed");
        assertEq(hook.quoteIsCurrency0(), quote0);
        uint256[32] memory rows = hook.canvas();
        bytes memory actualPixels = new bytes(1024);
        for (uint256 row; row < 32; ++row) {
            for (uint256 col; col < 32; ++col) {
                actualPixels[row * 32 + col] = bytes1(uint8(rows[row] >> (col * 8)));
            }
        }
        assertEq(actualPixels, pixels, "packed canvas disagrees with committed trade history");

        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint160 controlPrice, int24 controlTick,,) = manager.getSlot0(control.toId());
        assertEq(price, controlPrice);
        assertEq(tick, controlTick);
        assertEq(protocolFee, 0);
        assertEq(lpFee, 12500);
        assertEq(manager.getLiquidity(key.toId()), uint256(liquidity));
        assertEq(manager.getLiquidity(control.toId()), uint256(liquidity));
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(manager)), 1e27);
        assertEq(imd.balanceOf(address(this)) + imd.balanceOf(address(manager)), 1e30);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(imd))), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    /// @dev Called after each campaign: all liquidity and accrued fees must remain withdrawable.
    function exit() public {
        router.liquidity(key, -liquidity);
        router.liquidity(control, -liquidity);
        liquidity = 0;
        assertState();
    }
}

abstract contract PixelPoolInvariantBase is Test {
    using PoolIdLibrary for PoolKey;

    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    PixelPoolSequenceHandler internal handler;
    PixelToken internal token;
    PixelPoolHook internal hook;

    function quoteFirst() internal pure virtual returns (bool);

    function setUp() public {
        PoolManager manager = new PoolManager(address(this));
        bytes32 tokenHash = keccak256(type(PixelToken).creationCode);
        for (uint256 salt;; ++salt) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), tokenHash))))
            );
            if ((predicted > IMD) != quoteFirst()) continue;
            token = new PixelToken{salt: bytes32(salt)}();
            break;
        }
        vm.etch(IMD, address(new MockIMD()).code);
        // Runs the actual constructor at a permission-bearing address. CREATE2 salt validation
        // is covered by PixelPoolHook.t.sol; the manager itself is always deployed with new.
        address hookAddress = address(uint160(0x2040));
        deployCodeTo("PixelPoolHook.sol:PixelPoolHook", abi.encode(manager, token), hookAddress);
        hook = PixelPoolHook(hookAddress);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(quoteFirst() ? IMD : address(token)),
            currency1: Currency.wrap(quoteFirst() ? address(token) : IMD),
            fee: 12500,
            tickSpacing: 60,
            hooks: hook
        });
        manager.initialize(key, uint160(2 ** 96));
        PoolKey memory control = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(0)));
        manager.initialize(control, uint160(2 ** 96));
        handler = new PixelPoolSequenceHandler(manager, hook, token, key);
        token.transfer(address(handler), 1e27);
        MockIMD(IMD).mint(address(handler), 1e30);
        handler.setLiquidity(1e26);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.swapBatch.selector;
        selectors[2] = handler.setLiquidity.selector;
        selectors[3] = handler.rejectedCallback.selector;
        selectors[4] = handler.revertedSettlement.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function afterInvariant() public {
        handler.exit();
    }

    function test_MixedSequenceRepaintsAcrossPassBoundary() public {
        for (uint256 i; i < 132; ++i) {
            handler.swapBatch(8, i % 2 == 0 ? 1 ether : 1000 ether, i % 3 == 0);
            handler.revertedSettlement(i % 2 == 0);
            handler.rejectedCallback(uint8(i), true);
            handler.setLiquidity(i % 2 == 0 ? 1e26 : 1e25);
            handler.assertState();
        }
        assertEq(hook.strokes(), 1056);
        handler.exit();
    }

    function test_HookNeverMovesUnsolicitedTokenBalances() public {
        vm.prank(address(handler));
        token.transfer(address(hook), 7 ether);
        vm.prank(address(handler));
        MockIMD(IMD).transfer(address(hook), 9 ether);
        handler.swapBatch(8, 1000 ether, true);
        handler.revertedSettlement(false);
        assertEq(token.balanceOf(address(hook)), 7 ether);
        assertEq(MockIMD(IMD).balanceOf(address(hook)), 9 ether);
        assertEq(hook.strokes(), 8);
    }
}

contract PixelPoolIMD0InvariantTest is PixelPoolInvariantBase {
    function quoteFirst() internal pure override returns (bool) {
        return true;
    }

    /// @dev Spec: no hook fee or funds, immutable pool, exactly one ordered pixel per swap.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_TradeHistoryCanvasAndFundsAgree() public view {
        handler.assertState();
    }
}

contract PixelPoolIMD1InvariantTest is PixelPoolInvariantBase {
    function quoteFirst() internal pure override returns (bool) {
        return false;
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_TradeHistoryCanvasAndFundsAgree() public view {
        handler.assertState();
    }
}
