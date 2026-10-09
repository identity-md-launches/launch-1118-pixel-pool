// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelToken} from "src/PixelToken.sol";

/// @dev Closed actor set: all supply starts here, and every successful destination is tracked.
contract PixelTokenHandler is Test {
    PixelToken public immutable token;
    address[4] public actors;
    uint256[4] public expectedBalance;
    uint256[4][4] public expectedAllowance;

    constructor() {
        token = new PixelToken();
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("token actor ", vm.toString(i)));
            expectedBalance[i] = 1e27 / 4;
            assertTrue(token.transfer(actors[i], expectedBalance[i]));
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) public {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) public {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 to = toSeed % 4;
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 maximum = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = bound(rawAmount, 0, maximum);
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[owner], actors[to], amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    /// @dev Include meaningful delegated transfers even before the random sequence creates approvals.
    function approveAndSpend(uint256 owner, uint256 spender, uint256 to, uint256 amount, bool infinite) public {
        amount = bound(amount, 0, expectedBalance[owner % 4]);
        approve(owner, spender, infinite ? type(uint256).max : amount);
        transferFrom(owner, spender, to, amount);
    }

    function rejectTransfer(uint256 actorSeed, uint8 mode) public {
        uint256 actor = actorSeed % 4;
        address from = actors[actor];
        address to = actors[(actor + 1) % 4];
        if (mode % 3 == 0) {
            vm.prank(from);
            vm.expectRevert(PixelToken.InsufficientBalance.selector);
            token.transfer(to, expectedBalance[actor] + 1);
        } else if (mode % 3 == 1) {
            vm.prank(from);
            vm.expectRevert(PixelToken.ZeroAddress.selector);
            token.transfer(address(0), 0);
        } else {
            vm.prank(from);
            vm.expectRevert(PixelToken.ZeroAddress.selector);
            token.approve(address(0), type(uint256).max);
        }
    }

    /// @dev A revert after spending allowance must roll it back, including self-spender cases.
    function rejectDelegatedTransfer(uint256 ownerSeed, uint256 spenderSeed, uint8 mode) public {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        address to = actors[(owner + 1) % 4];
        if (mode % 3 == 0) {
            approve(owner, spender, 0);
            vm.prank(actors[spender]);
            vm.expectRevert(PixelToken.InsufficientAllowance.selector);
            token.transferFrom(actors[owner], to, 1);
        } else if (mode % 3 == 1) {
            uint256 excessive = expectedBalance[owner] + 1;
            approve(owner, spender, excessive);
            vm.prank(actors[spender]);
            vm.expectRevert(PixelToken.InsufficientBalance.selector);
            token.transferFrom(actors[owner], to, excessive);
        } else {
            approve(owner, spender, 1);
            vm.prank(actors[spender]);
            vm.expectRevert(PixelToken.ZeroAddress.selector);
            token.transferFrom(actors[owner], address(0), 1);
        }
    }

    function assertAccounting() public view {
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            uint256 actual = token.balanceOf(actors[i]);
            assertEq(actual, expectedBalance[i], "a holder gained or lost unrequested tokens");
            total += actual;
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), expectedAllowance[i][j], "allowance mismatch");
            }
        }
        assertEq(total, 1e27, "all minted tokens remain accounted for");
        assertEq(token.totalSupply(), total, "supply changed");
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}

contract PixelTokenInvariantTest is Test {
    PixelTokenHandler private handler;

    function setUp() public {
        handler = new PixelTokenHandler();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.approveAndSpend.selector;
        selectors[4] = handler.rejectTransfer.selector;
        selectors[5] = handler.rejectDelegatedTransfer.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev Spec: fixed supply, ordinary untaxed transfers, and standard spending authorization.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_BalancesAndAllowancesMatchEveryAuthorizedAction() public view {
        handler.assertAccounting();
    }

    function test_SelfSpendRevocationAndFailedSpendSequence() public {
        handler.approveAndSpend(0, 0, 0, type(uint256).max, true);
        handler.assertAccounting();
        handler.transferFrom(0, 0, 1, type(uint256).max);
        handler.approve(0, 0, 0);
        handler.rejectDelegatedTransfer(0, 0, 0);
        handler.rejectDelegatedTransfer(1, 2, 1);
        handler.rejectDelegatedTransfer(1, 2, 2);
        handler.assertAccounting();
        // Full-supply ownership changes, then a full-supply self-transfer.
        handler.transfer(2, 1, type(uint256).max);
        handler.transfer(3, 1, type(uint256).max);
        handler.transfer(1, 1, type(uint256).max);
        handler.assertAccounting();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RevokedAllowanceCannotBeSpent(uint256 approval, uint256 amount) public {
        handler.approve(0, 1, approval);
        handler.transferFrom(0, 1, 2, amount);
        handler.approve(0, 1, 0);
        PixelToken token = handler.token();
        address owner = handler.actors(0);
        address spender = handler.actors(1);
        address recipient = handler.actors(2);
        vm.prank(spender);
        vm.expectRevert(PixelToken.InsufficientAllowance.selector);
        token.transferFrom(owner, recipient, bound(amount, 1, type(uint256).max));
        handler.assertAccounting();
    }
}
