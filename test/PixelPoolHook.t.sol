// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelPoolHook} from "../src/PixelPoolHook.sol";
import {PixelToken} from "../src/PixelToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {MockIMD} from "./helpers/MockIMD.sol";

/// @dev Every inherited test runs with a real PoolManager in each currency ordering.
abstract contract PixelPoolHookTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint160 internal constant PRICE = 79228162514264337593543950336;
    int256 internal constant LIQUIDITY = 1e26;

    PoolManager internal manager;
    PixelPoolHook internal hook;
    PixelToken internal token;
    MockIMD internal imd;
    PoolRouter internal router;
    PoolKey internal key;

    event Painted(uint256 indexed stroke, uint256 indexed pixel, uint8 color, address indexed painter);

    function _quoteIs0() internal pure virtual returns (bool);

    function setUp() public {
        manager = new PoolManager(address(this));
        // CREATE2 deploys the real token on the chosen side of the fixed IMD address.
        bytes32 tokenHash = keccak256(type(PixelToken).creationCode);
        for (uint256 i;; ++i) {
            address predicted = _predict(bytes32(i), tokenHash);
            if ((predicted > IMD) == _quoteIs0()) {
                token = new PixelToken{salt: bytes32(i)}();
                break;
            }
        }
        vm.etch(IMD, address(new MockIMD()).code);
        imd = MockIMD(IMD);
        imd.mint(address(this), 1e30);
        (bytes32 salt,) = _mineHook();
        hook = new PixelPoolHook{salt: salt}(manager, address(token));
        key = _key(IHooks(address(hook)));
        router = new PoolRouter(manager);
        token.approve(address(router), 1e27);
        imd.approve(address(router), 1e30);
    }

    function _predict(bytes32 salt, bytes32 codeHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
    }

    function _mineHook() internal view returns (bytes32 salt, address predicted) {
        bytes32 codeHash = keccak256(abi.encodePacked(type(PixelPoolHook).creationCode, abi.encode(manager, token)));
        for (uint256 i; i < 200_000; ++i) {
            predicted = _predict(bytes32(i), codeHash);
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == 0x2040 && predicted.code.length == 0) {
                return (bytes32(i), predicted);
            }
        }
        revert("no hook salt");
    }

    function _key(IHooks target) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(_quoteIs0() ? IMD : address(token)),
            currency1: Currency.wrap(_quoteIs0() ? address(token) : IMD),
            fee: 12500,
            tickSpacing: 60,
            hooks: target
        });
    }

    function _open() internal {
        manager.initialize(key, PRICE);
        router.liquidity(key, LIQUIDITY);
    }

    function _params(bool buy, int256 specified) internal pure returns (SwapParams memory) {
        bool zeroForOne = buy == _quoteIs0();
        return SwapParams(zeroForOne, specified, zeroForOne ? uint160(2 ** 95) : uint160(2 ** 97));
    }

    function _quoteSwap(bool buy, uint256 amount) internal returns (BalanceDelta delta) {
        delta = router.swap(key, _params(buy, buy ? -int256(amount) : int256(amount)));
        int128 quote = _quoteIs0() ? delta.amount0() : delta.amount1();
        assertEq(int256(quote), buy ? -int256(amount) : int256(amount));
    }

    function _wrappedInitError(bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeInitialize.selector,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function test_PermissionsAndImmutableBindings() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        expected.afterSwap = true;
        assertEq(abi.encode(p), abi.encode(expected));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x2040);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
        assertEq(hook.IMD(), IMD);
        assertLt(address(hook).code.length, 24576);
    }

    function test_InitializationLocksPoolAndStartsEmpty() public {
        address factory = makeAddr("launch factory");
        vm.prank(factory);
        manager.initialize(key, PRICE);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(hook.quoteIsCurrency0(), _quoteIs0());
        assertEq(hook.strokes(), 0);
        uint256[32] memory grid = hook.canvas();
        for (uint256 i; i < 32; ++i) {
            assertEq(grid[i], 0);
        }
        (uint160 price,, uint24 protocolFee, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, PRICE);
        assertEq(lpFee, 12500);
        assertEq(protocolFee, 0);
    }

    function test_DotsPaintInOrderAndPackedRowsAreLittleEndian() public {
        _open();
        router.batch(key, _params(true, -1 ether), 65, true);
        assertEq(hook.strokes(), 65);
        uint256[32] memory grid = hook.canvas();
        for (uint256 row; row < 32; ++row) {
            uint256 expected;
            for (uint256 col; col < 32; ++col) {
                uint256 pixel = row * 32 + col;
                uint8 color = pixel < 65 ? (pixel % 2 == 0 ? 1 : 5) : 0;
                assertEq(hook.pixelAt(pixel), color);
                expected |= uint256(color) << (col * 8);
            }
            assertEq(grid[row], expected);
        }
    }

    function test_AllShadeThresholdsBothDirections() public {
        _open();
        uint256[8] memory amounts =
            [uint256(1), 5 ether - 1, 5 ether, 50 ether - 1, 50 ether, 500 ether - 1, 500 ether, 1000 ether];
        uint8[8] memory shades = [uint8(0), 0, 1, 1, 2, 2, 3, 3];
        for (uint256 i; i < amounts.length; ++i) {
            _quoteSwap(true, amounts[i]);
            assertEq(hook.pixelAt(i * 2), 1 + shades[i]);
            _quoteSwap(false, amounts[i]);
            assertEq(hook.pixelAt(i * 2 + 1), 5 + shades[i]);
        }
        assertEq(hook.strokes(), 16);
    }

    function test_ExactOutputBuyAndExactInputSellUseActualIMDDelta() public {
        _open();
        // The PIXEL amount alone is insufficient: the quote amount includes LP fee and price impact.
        BalanceDelta buy = router.swap(key, _params(true, 499 ether));
        int256 quote = _quoteIs0() ? int256(buy.amount0()) : int256(buy.amount1());
        assertLt(quote, -500 ether);
        assertEq(hook.pixelAt(0), 4);
        BalanceDelta sell = router.swap(key, _params(false, -500 ether));
        quote = _quoteIs0() ? int256(sell.amount0()) : int256(sell.amount1());
        assertGt(quote, 50 ether);
        assertLt(quote, 500 ether);
        assertEq(hook.pixelAt(1), 7);
    }

    function test_PriceLimitedPartialFillUsesExecutedQuoteAmount() public {
        _open();
        SwapParams memory params = _params(true, -1000 ether);
        // With liquidity 1e26 this very small move executes about 1.3 IMD.
        params.sqrtPriceLimitX96 = params.zeroForOne ? PRICE - 1e21 : PRICE + 1e21;
        BalanceDelta delta = router.swap(key, params);
        int256 quote = _quoteIs0() ? int256(delta.amount0()) : int256(delta.amount1());
        assertLt(quote, 0);
        assertGt(quote, -5 ether);
        assertEq(hook.pixelAt(0), 1);
    }

    function test_SecondPassRepaintsOnlyVisitedPixels() public {
        _open();
        router.batch(key, _params(true, -1000 ether), 1024, false);
        assertEq(hook.strokes(), 1024);
        for (uint256 i; i < 1024; ++i) {
            assertEq(hook.pixelAt(i), 4);
        }
        router.batch(key, _params(false, -1 ether), 33, false);
        assertEq(hook.strokes(), 1057);
        for (uint256 i; i < 1024; ++i) {
            assertEq(hook.pixelAt(i), i < 33 ? 5 : 4);
        }
        uint256[32] memory grid = hook.canvas();
        assertEq(uint8(grid[0]), 5);
        assertEq(uint8(grid[0] >> 248), 5);
        assertEq(uint8(grid[1]), 5);
        assertEq(uint8(grid[1] >> 8), 4);
        router.batch(key, _params(false, -1 ether), 991, false);
        assertEq(hook.strokes(), 2048);
        for (uint256 i; i < 1024; ++i) {
            assertEq(hook.pixelAt(i), 5);
        }
        _quoteSwap(true, 1 ether);
        assertEq(hook.strokes(), 2049);
        assertEq(hook.pixelAt(0), 1);
        assertEq(hook.pixelAt(1), 5);
    }

    function test_PaintedEventUsesOriginRatherThanRouter() public {
        _open();
        address origin = makeAddr("transaction origin");
        vm.expectEmit(true, true, true, true, address(hook));
        emit Painted(1, 0, 1, origin);
        vm.prank(address(this), origin);
        router.swap(key, _params(true, -1 ether));
    }

    function test_OnlyManagerCanCallEnabledCallbacks() public {
        vm.expectRevert(PixelPoolHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(manager), key, PRICE);
        vm.expectRevert(PixelPoolHook.OnlyPoolManager.selector);
        hook.afterSwap(address(manager), key, _params(true, -1 ether), toBalanceDelta(-1 ether, 1 ether), "");
        _open();
        vm.expectRevert(PixelPoolHook.OnlyPoolManager.selector);
        hook.afterSwap(address(manager), key, _params(true, -1 ether), toBalanceDelta(-1 ether, 1 ether), "");
        assertEq(hook.strokes(), 0);
    }

    function test_SwapsCannotPaintBeforeInitialization() public {
        vm.prank(address(manager));
        vm.expectRevert(PixelPoolHook.NotInitialized.selector);
        hook.afterSwap(address(router), key, _params(true, -1 ether), toBalanceDelta(-1 ether, 1 ether), "");
    }

    function test_RejectsRepeatInitializationAndAnySecondPool() public {
        manager.initialize(key, PRICE);
        vm.expectRevert(_wrappedInitError(PixelPoolHook.AlreadyInitialized.selector));
        manager.initialize(key, PRICE);
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert(_wrappedInitError(PixelPoolHook.AlreadyInitialized.selector));
        manager.initialize(other, PRICE);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
    }

    function test_RejectsWrongPairFeeSpacingAndHook() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert(_wrappedInitError(PixelPoolHook.InvalidPool.selector));
        manager.initialize(other, PRICE);
        other.fee = 0;
        vm.expectRevert(_wrappedInitError(PixelPoolHook.InvalidPool.selector));
        manager.initialize(other, PRICE);
        other.fee = 0x800000;
        vm.expectRevert(_wrappedInitError(PixelPoolHook.InvalidPool.selector));
        manager.initialize(other, PRICE);
        other.fee = 12500;
        other.tickSpacing = 10;
        vm.expectRevert(_wrappedInitError(PixelPoolHook.InvalidPool.selector));
        manager.initialize(other, PRICE);
        other.tickSpacing = 60;
        // A sorted unrelated pair must not lock the hook before the launch arrives.
        address third = address(new PixelToken());
        (other.currency0, other.currency1) =
            third < IMD ? (Currency.wrap(third), Currency.wrap(IMD)) : (Currency.wrap(IMD), Currency.wrap(third));
        vm.expectRevert(_wrappedInitError(PixelPoolHook.InvalidPool.selector));
        manager.initialize(other, PRICE);
        other = _key(IHooks(address(router)));
        vm.prank(address(manager));
        vm.expectRevert(PixelPoolHook.InvalidPool.selector);
        hook.beforeInitialize(address(this), other, PRICE);
        other = _key(hook);
        (other.currency0, other.currency1) = (other.currency1, other.currency0);
        vm.prank(address(manager));
        vm.expectRevert(PixelPoolHook.InvalidPool.selector);
        hook.beforeInitialize(address(this), other, PRICE);
        manager.initialize(key, PRICE);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
    }

    function test_WrongPoolSwapLeavesCanvasUnchanged() public {
        _open();
        _quoteSwap(true, 1 ether);
        PoolKey memory other = key;
        other.tickSpacing = 120;
        vm.prank(address(manager));
        vm.expectRevert(PixelPoolHook.InvalidPool.selector);
        hook.afterSwap(address(router), other, _params(false, -1 ether), toBalanceDelta(1 ether, -1 ether), "");
        assertEq(hook.strokes(), 1);
        assertEq(hook.pixelAt(0), 1);
        assertEq(hook.pixelAt(1), 0);
    }

    function test_FailedInitializationRollsBackThePoolLock() public {
        vm.expectRevert(); // PoolManager rejects an out-of-range opening price after beforeInitialize.
        manager.initialize(key, 1);
        assertEq(PoolId.unwrap(hook.poolId()), bytes32(0));
        manager.initialize(key, PRICE + 1);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
    }

    function test_CannotInitializePredictedHookWithoutCode() public {
        (bytes32 salt, address predicted) = _mineHook();
        PoolKey memory predictedKey = _key(IHooks(predicted));
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(predictedKey, PRICE);
        PixelPoolHook deployed = new PixelPoolHook{salt: salt}(manager, address(token));
        assertEq(address(deployed), predicted);
        manager.initialize(predictedKey, PRICE);
        assertEq(PoolId.unwrap(deployed.poolId()), PoolId.unwrap(predictedKey.toId()));
    }

    function test_ConstructorRejectsIncorrectPermissionBitsAndInvalidContracts() public {
        bytes32 codeHash = keccak256(abi.encodePacked(type(PixelPoolHook).creationCode, abi.encode(manager, token)));
        bytes32 salt;
        address predicted = _predict(salt, codeHash);
        assertTrue((uint160(predicted) & Hooks.ALL_HOOK_MASK) != 0x2040);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new PixelPoolHook{salt: salt}(manager, address(token));
        vm.expectRevert(PixelPoolHook.InvalidManager.selector);
        new PixelPoolHook(IPoolManager(makeAddr("no manager code")), address(token));
        vm.expectRevert(PixelPoolHook.InvalidToken.selector);
        new PixelPoolHook(manager, makeAddr("no token code"));
        vm.expectRevert(PixelPoolHook.InvalidToken.selector);
        new PixelPoolHook(manager, IMD);
    }

    function test_AllDisabledCallbacksRevert() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = toBalanceDelta(0, 0);
        vm.expectRevert(PixelPoolHook.HookNotEnabled.selector);
        hook.afterInitialize(address(this), key, PRICE, 0);
        vm.expectRevert(PixelPoolHook.HookNotEnabled.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(PixelPoolHook.HookNotEnabled.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(PixelPoolHook.HookNotEnabled.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(PixelPoolHook.HookNotEnabled.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(PixelPoolHook.HookNotEnabled.selector);
        hook.beforeSwap(address(this), key, _params(true, -1 ether), "");
        vm.expectRevert(PixelPoolHook.HookNotEnabled.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(PixelPoolHook.HookNotEnabled.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
    }

    function test_RevertedSettlementRollsBackPainting() public {
        _open();
        imd.approve(address(router), 0);
        vm.expectRevert(); // Swaps paint first, but the router then cannot pay the manager.
        router.swap(key, _params(true, -1 ether));
        assertEq(hook.strokes(), 0);
        assertEq(hook.pixelAt(0), 0);
    }

    function test_NoHookFundsClaimsOrDeltasAndLiquidityCanBeWithdrawn() public {
        _open();
        assertEq(address(manager).balance, 0);
        uint256 beforeIMD = imd.balanceOf(address(this));
        uint256 beforePIXEL = token.balanceOf(address(this));
        BalanceDelta delta = _quoteSwap(true, 100 ether);
        uint256 received = uint256(int256(_quoteIs0() ? delta.amount1() : delta.amount0()));
        assertEq(imd.balanceOf(address(this)), beforeIMD - 100 ether);
        assertEq(token.balanceOf(address(this)), beforePIXEL + received);
        _quoteSwap(false, 50 ether);
        router.liquidity(key, -LIQUIDITY);
        assertEq(hook.strokes(), 2);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), key.currency0), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), key.currency1), 0);
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0);
    }

    function test_ZeroDeltaAndMinimumInt128AreSafeAndReturnNoDelta() public {
        manager.initialize(key, PRICE);
        vm.prank(address(manager));
        (bytes4 selector, int128 returned) =
            hook.afterSwap(address(router), key, _params(true, -1), toBalanceDelta(0, 0), "");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(returned, 0);
        assertEq(hook.pixelAt(0), 1);
        BalanceDelta minimum = _quoteIs0() ? toBalanceDelta(type(int128).min, 1) : toBalanceDelta(1, type(int128).min);
        vm.prank(address(manager));
        (, returned) = hook.afterSwap(address(router), key, _params(true, -1), minimum, "ignored");
        assertEq(returned, 0);
        assertEq(hook.pixelAt(1), 4);
    }

    function test_EmptyPoolSwapStillPaintsOneDot() public {
        manager.initialize(key, PRICE);
        BalanceDelta delta = router.swap(key, _params(true, -1 ether));
        assertEq(BalanceDelta.unwrap(delta), 0);
        assertEq(hook.strokes(), 1);
        assertEq(hook.pixelAt(0), 1);
    }

    function test_RejectsWrongQuoteCurrency() public {
        address other = address(new PixelToken());
        PoolKey memory wrong = key;
        (wrong.currency0, wrong.currency1) = other < address(token)
            ? (Currency.wrap(other), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(other));
        vm.expectRevert(_wrappedInitError(PixelPoolHook.InvalidPool.selector));
        manager.initialize(wrong, PRICE);
        manager.initialize(key, PRICE);
    }

    function test_NoAdminSelectorsOrRuntimeEscapeHatches() public {
        bytes[6] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("upgradeTo(address)", address(token)),
            abi.encodeWithSignature("setFee(uint256)", 1),
            abi.encodeWithSignature("withdraw()")
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok);
        }
        _scanRuntime(address(hook));
        _scanRuntime(address(token));
    }

    function _scanRuntime(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            }
        }
    }

    function testFuzz_RealSwapMatchesPoolWithNoHook(uint96 rawAmount, bool buy, bool exactInput) public {
        uint256 amount = bound(rawAmount, 1 ether, 100_000 ether);
        _open();
        // A zero hooks field is Uniswap's explicit no-hook pool type.
        PoolKey memory plain = _key(IHooks(address(0)));
        manager.initialize(plain, PRICE);
        router.liquidity(plain, LIQUIDITY);
        SwapParams memory params = _params(buy, exactInput ? -int256(amount) : int256(amount));
        BalanceDelta hooked = router.swap(key, params);
        BalanceDelta unhooked = router.swap(plain, params);
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(unhooked), "hook must not alter swap amounts");
        assertEq(hook.strokes(), 1, "the unrelated pool must not paint");
        int256 quote = _quoteIs0() ? int256(hooked.amount0()) : int256(hooked.amount1());
        uint256 absolute = uint256(quote < 0 ? -quote : quote);
        uint8 expected = buy ? 1 : 5;
        if (absolute >= 5 ether) ++expected;
        if (absolute >= 50 ether) ++expected;
        if (absolute >= 500 ether) ++expected;
        assertEq(hook.pixelAt(0), expected);
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0);
    }

    function testFuzz_PaintsFromQuoteDeltaRegardlessOfOtherCurrency(int128 quote, int128 other, bool buy) public {
        manager.initialize(key, PRICE);
        BalanceDelta delta = _quoteIs0() ? toBalanceDelta(quote, other) : toBalanceDelta(other, quote);
        vm.prank(address(manager));
        (, int128 returned) = hook.afterSwap(address(router), key, _params(buy, -1 ether), delta, "");
        int256 wide = quote;
        uint256 amount = uint256(wide < 0 ? -wide : wide);
        uint8 expected = buy ? 1 : 5;
        if (amount >= 5 ether) ++expected;
        if (amount >= 50 ether) ++expected;
        if (amount >= 500 ether) ++expected;
        assertEq(hook.pixelAt(0), expected);
        assertEq(hook.strokes(), 1);
        assertEq(returned, 0);
    }

    function testFuzz_OutOfRangePixelReverts(uint256 index) public {
        index = bound(index, 1024, type(uint256).max);
        vm.expectRevert(PixelPoolHook.PixelOutOfBounds.selector);
        hook.pixelAt(index);
    }

    function test_RenderEmptyCanvasHasAllDots() public view {
        _checkSvg(hook.render());
    }

    function test_RenderFullCanvasUnder15MillionGas() public {
        _open();
        for (uint256 shade; shade < 4; ++shade) {
            uint256 amount = shade == 0 ? 1 ether : shade == 1 ? 10 ether : shade == 2 ? 100 ether : 1000 ether;
            router.batch(key, _params(true, -int256(amount)), 128, false);
            router.batch(key, _params(false, int256(amount)), 128, false);
        }
        assertEq(hook.strokes(), 1024);
        vm.cool(address(hook));
        uint256 before = gasleft();
        string memory svg = hook.render();
        uint256 used = before - gasleft();
        emit log_named_uint("render gas (cold full canvas)", used);
        assertLt(used, 15_000_000);
        _checkSvg(svg);
    }

    function _checkSvg(string memory svg) internal view {
        // Independent, intentionally simple reference renderer checks every coordinate and palette entry.
        string[9] memory palette =
            [string("#0b0b12"), "#1f7a3d", "#22b455", "#2ee66b", "#8dffad", "#7a1f1f", "#c42b2b", "#ff3b3b", "#ff9a9a"];
        bytes memory output = bytes(svg);
        bytes memory prefix = bytes(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320"><rect width="320" height="320" fill="#0b0b12"/>'
        );
        assertEq(output.length, prefix.length + 1024 * 48 + 6);
        for (uint256 i; i < prefix.length; ++i) {
            assertEq(output[i], prefix[i]);
        }
        for (uint256 i; i < 1024; ++i) {
            bytes memory expected = bytes(
                string.concat(
                    '<circle cx="',
                    _padded(5 + (i % 32) * 10),
                    '" cy="',
                    _padded(5 + (i / 32) * 10),
                    '" r="4" fill="',
                    palette[hook.pixelAt(i)],
                    '"/>'
                )
            );
            bytes32 actualHash;
            uint256 offset = prefix.length + 48 * i;
            assembly ("memory-safe") {
                actualHash := keccak256(add(add(output, 32), offset), 48)
            }
            assertEq(actualHash, keccak256(expected), "SVG dot mismatch");
        }
        bytes memory end = bytes("</svg>");
        for (uint256 i; i < 6; ++i) {
            assertEq(output[output.length - 6 + i], end[i]);
        }
    }

    function _padded(uint256 value) internal pure returns (string memory) {
        return string.concat(value < 10 ? "00" : value < 100 ? "0" : "", vm.toString(value));
    }
}

contract PixelPoolHookIMD0Test is PixelPoolHookTestBase {
    function _quoteIs0() internal pure override returns (bool) {
        return true;
    }
}

contract PixelPoolHookIMD1Test is PixelPoolHookTestBase {
    function _quoteIs0() internal pure override returns (bool) {
        return false;
    }
}
