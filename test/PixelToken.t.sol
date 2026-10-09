// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelToken} from "../src/PixelToken.sol";

contract PixelTokenTest is Test {
    PixelToken private token;
    address private alice;
    address private bob;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function setUp() public {
        token = new PixelToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_MetadataAndSupply() public view {
        assertEq(token.name(), "Pixel Pool");
        assertEq(token.symbol(), "PIXEL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_ConstructorMintsToActualDeployer() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, 1e27);
        PixelToken deployed = new PixelToken();
        assertEq(deployed.balanceOf(alice), 1e27);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function test_TransfersEmitAndHaveNoTax() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 42 ether);
        assertTrue(token.transfer(alice, 42 ether));
        assertEq(token.balanceOf(alice), 42 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 42 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_ApprovalAndTransferFrom() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), alice, 30 ether);
        assertTrue(token.approve(alice, 30 ether));
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 20 ether));
        assertEq(token.allowance(address(this), alice), 10 ether);
        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 20 ether);
        token.approve(alice, 0);
        vm.prank(alice);
        vm.expectRevert(PixelToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), bob, 1);
    }

    function test_InfiniteAllowanceAndSelfTransfers() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1 ether);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
        uint256 before = token.balanceOf(address(this));
        token.transfer(address(this), before);
        assertEq(token.balanceOf(address(this)), before);
        vm.prank(bob);
        token.transfer(alice, 0);
        assertEq(token.balanceOf(bob), 1 ether);
    }

    function test_RejectsInvalidTransfersAndRestoresAllowance() public {
        vm.expectRevert(PixelToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(PixelToken.ZeroAddress.selector);
        token.approve(address(0), 1);
        vm.prank(alice);
        vm.expectRevert(PixelToken.InsufficientBalance.selector);
        token.transfer(bob, 1);
        token.approve(alice, 1e27 + 1);
        vm.prank(alice);
        vm.expectRevert(PixelToken.InsufficientBalance.selector);
        token.transferFrom(address(this), bob, 1e27 + 1);
        assertEq(token.allowance(address(this), alice), 1e27 + 1);
        vm.prank(alice);
        vm.expectRevert(PixelToken.ZeroAddress.selector);
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.balanceOf(address(this)), 1e27);
        vm.expectRevert(PixelToken.ZeroAddress.selector);
        token.transferFrom(address(0), alice, 0);
    }

    function test_NoMintOrAdminSelectors() public {
        bytes[8] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether),
            abi.encodeWithSignature("burn(uint256)", 1 ether),
            abi.encodeWithSignature("transferOwnership(address)", alice),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("upgradeTo(address)", alice),
            abi.encodeWithSignature("initialize(address)", alice),
            abi.encodeWithSignature("setTax(uint256)", 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_ConservationAcrossTransfers(uint256 first, uint256 second) public {
        first = bound(first, 0, 1e27);
        second = bound(second, 0, first);
        token.transfer(alice, first);
        vm.prank(alice);
        token.approve(bob, second);
        vm.prank(bob);
        token.transferFrom(alice, bob, second);
        assertEq(token.balanceOf(alice), first - second);
        assertEq(token.balanceOf(bob), second);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob), 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.allowance(alice, bob), 0);
    }
}
