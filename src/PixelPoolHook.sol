// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice One immutable PIXEL/IMD pool, one dot per swap, no hook fees or fund movements.
contract PixelPoolHook is IHooks {
    using PoolIdLibrary for PoolKey;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    IPoolManager public immutable poolManager;
    address public immutable token;

    PoolId public poolId;
    bool public quoteIsCurrency0;
    bool private initialized;
    uint256 public strokes;
    // Each row is 32 bytes. Column zero occupies the least significant byte.
    uint256[32] private rows;

    error OnlyPoolManager();
    error InvalidManager();
    error InvalidToken();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidPool();
    error PixelOutOfBounds();
    error HookNotEnabled();

    event Painted(uint256 indexed stroke, uint256 indexed pixel, uint8 color, address indexed painter);

    constructor(IPoolManager manager, address token_) {
        if (address(manager).code.length == 0) revert InvalidManager();
        if (token_.code.length == 0 || token_ == IMD) revert InvalidToken();
        poolManager = manager;
        token = token_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.afterSwap = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (initialized) revert AlreadyInitialized();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != address(this) || key.fee != 12500 || key.tickSpacing != 60 || c0 >= c1
                || !((c0 == token && c1 == IMD) || (c0 == IMD && c1 == token))
        ) revert InvalidPool();

        poolId = key.toId();
        quoteIsCurrency0 = c0 != token;
        initialized = true;
        return IHooks.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!initialized) revert NotInitialized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();

        // Widen before negation so int128.min is also handled correctly.
        int256 quoteDelta = quoteIsCurrency0 ? int256(delta.amount0()) : int256(delta.amount1());
        uint256 amount = uint256(quoteDelta < 0 ? -quoteDelta : quoteDelta);
        uint8 shade = amount < 5 ether ? 0 : amount < 50 ether ? 1 : amount < 500 ether ? 2 : 3;
        bool buy = params.zeroForOne == quoteIsCurrency0;
        uint8 color = (buy ? 1 : 5) + shade;

        uint256 stroke = ++strokes;
        uint256 pixel = (stroke - 1) % 1024;
        uint256 row = pixel / 32;
        uint256 shift = (pixel % 32) * 8;
        rows[row] = (rows[row] & ~(uint256(0xff) << shift)) | (uint256(color) << shift);

        // Attribution only: tx.origin never authorizes an action or receives funds.
        emit Painted(stroke, pixel, color, tx.origin);
        return (IHooks.afterSwap.selector, 0);
    }

    function pixelAt(uint256 i) external view returns (uint8) {
        if (i >= 1024) revert PixelOutOfBounds();
        return uint8(rows[i / 32] >> ((i % 32) * 8));
    }

    function canvas() external view returns (uint256[32] memory) {
        return rows;
    }

    /// @notice All 1024 dots as a standalone SVG, including empty dots.
    /// @dev Allocate the exact output size once; reuse a fixed-size circle template.
    function render() external view returns (string memory) {
        bytes memory header = bytes(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320"><rect width="320" height="320" fill="#0b0b12"/>'
        );
        bytes memory dot = bytes('<circle cx="000" cy="000" r="4" fill="#000000"/>');
        bytes memory palette = bytes("0b0b121f7a3d22b4552ee66b8dffad7a1f1fc42b2bff3b3bff9a9a");
        bytes memory result = new bytes(header.length + 1024 * dot.length + 6);
        uint256 cursor = _copy(result, 0, header);

        for (uint256 y; y < 32; ++y) {
            uint256 row = rows[y];
            _coordinate(dot, 21, y * 10 + 5);
            for (uint256 x; x < 32; ++x) {
                _coordinate(dot, 12, x * 10 + 5);
                uint256 colorOffset = uint256(uint8(row)) * 6;
                for (uint256 c; c < 6; ++c) {
                    dot[39 + c] = palette[colorOffset + c];
                }
                cursor = _copy(result, cursor, dot);
                row >>= 8;
            }
        }
        _copy(result, cursor, bytes("</svg>"));
        return string(result);
    }

    // Coordinates range from 005 to 315; leading zeroes are valid SVG numbers.
    function _coordinate(bytes memory target, uint256 offset, uint256 value) private pure {
        target[offset] = bytes1(uint8(48 + value / 100));
        target[offset + 1] = bytes1(uint8(48 + (value / 10) % 10));
        target[offset + 2] = bytes1(uint8(48 + value % 10));
    }

    function _copy(bytes memory target, uint256 offset, bytes memory source) private pure returns (uint256) {
        // Callers allocate the exact total size and only append bounded fragments.
        assembly ("memory-safe") {
            mcopy(add(add(target, 0x20), offset), add(source, 0x20), mload(source))
        }
        return offset + source.length;
    }

    // IHooks requires these selectors, but the address enables none of them.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotEnabled();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotEnabled();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotEnabled();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotEnabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotEnabled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotEnabled();
    }
}
