// SPDX-License-Identifier: MITrebalance
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {JITRebalancer} from "../src/JITRebalancer.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";
import {HelperConfig} from "../script/HelperConfig.sol";

contract JITRebalancerTest is Test {
    JITRebalancer jitRebalancer;
    MockERC20 token0;
    MockERC20 token1;
    address manager = makeAddr("manager");
    address router = makeAddr("router");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public {
        token0 = new MockERC20();
        token1 = new MockERC20();

        HelperConfig aggregatorPriceFeed = new HelperConfig();
        (address wethUsdPriceFeed, , ) = aggregatorPriceFeed
            .activeNetworkConfig();
        console2.log("wethUsdPriceFeed", wethUsdPriceFeed);
        // to be changed later
        jitRebalancer = new JITRebalancer(
            address(token0),
            address(token1),
            router,
            wethUsdPriceFeed
        );
    }

    function test_deposit() public {
        vm.startPrank(user1);
        token0.mint(user1, 1 ether);
        token1.mint(user1, 1 ether);
        token1.mint(address(jitRebalancer), 1 ether);
        token0.approve(address(jitRebalancer), 1 ether);
        token1.approve(address(jitRebalancer), 1 ether);
        jitRebalancer.depositLiquidity(0.5 ether, 0.5 ether);
        console2.log(jitRebalancer.balanceOf(user1));
        jitRebalancer.depositLiquidity(0.5 ether, 0.5 ether);
        console2.log(" User 1 Balance After Deposit",jitRebalancer.balanceOf(user1));
        console2.log("--------------------------------");
        vm.stopPrank();

        vm.startPrank(user2);
        token0.mint(user2, 1 ether);
        token1.mint(user2, 1 ether);
        token0.approve(address(jitRebalancer), 1 ether);
        token1.approve(address(jitRebalancer), 1 ether);
        jitRebalancer.depositLiquidity(0.5 ether, 0.5 ether);
        vm.stopPrank();

        vm.startPrank(user1);
        jitRebalancer.withdrawLiquidity(1 ether, user1);
        console2.log(
            jitRebalancer.balanceOf(user1),
            token0.balanceOf(user1),
            token1.balanceOf(user1)
        );
        assertEq(jitRebalancer.balanceOf(user1), 0);
        assertApproxEqAbs(
            token0.balanceOf(user1),
            (jitRebalancer.totalDepositedToken0() * 1 ether) /
                jitRebalancer.totalSupply(),
            10 wei,
            "not eq token 0"
        );
        // (token0.balanceOf(user1), token0.balanceOf(address(jitRebalancer)) * 1 ether / jitRebalancer.totalSupply());
        assertApproxEqAbs(
            token1.balanceOf(user1),
            (jitRebalancer.totalDepositedToken1() * 1 ether) /
                jitRebalancer.totalSupply(),
            10 wei,
            "not eq token 1"
        );

        // assertEq(token1.balanceOf(user1), token1.balanceOf(address(jitRebalancer)) * 1 ether / jitRebalancer.totalSupply());
    }

    function testWithdrawLiquidity() public {
        // Initial deposits for user1
        vm.startPrank(user1);
        token0.mint(user1, 1 ether);
        token1.mint(user1, 1 ether);
        token0.approve(address(jitRebalancer), 1 ether);
        token1.approve(address(jitRebalancer), 1 ether);

        // User1 deposits 0.5 ether of token0 and token1
        jitRebalancer.depositLiquidity(0.5 ether, 0.5 ether);
        console2.log(
            "User1 Token0 Balance After Deposit",
            token0.balanceOf(user1)
        );
        console2.log(
            "User1 Token1 Balance After Deposit",
            token1.balanceOf(user1)
        );
        console2.log(
            "JIT Balance After User1 Deposit",
            jitRebalancer.balanceOf(user1)
        );

        assertEq(
            jitRebalancer.balanceOf(user1),
            0.5 ether,
            "Initial deposit not equal"
        );

        vm.stopPrank();

        // Initial deposits for user2
        vm.startPrank(user2);
        token0.mint(user2, 1 ether);
        token1.mint(user2, 1 ether);
        token0.approve(address(jitRebalancer), 1 ether);
        token1.approve(address(jitRebalancer), 1 ether);

        // User2 deposits 0.5 ether of token0 and token1
        jitRebalancer.depositLiquidity(0.5 ether, 0.5 ether);
        console2.log(
            "User2 Token0 Balance After Deposit",
            token0.balanceOf(user1)
        );
        console2.log(
            "User2 Token1 Balance After Deposit",
            token1.balanceOf(user1)
        );
        console2.log(
            "JIT Balance After User2 Deposit",
            jitRebalancer.balanceOf(user1)
        );

        assertEq(
            jitRebalancer.balanceOf(user2),
            0.5 ether,
            "User2 deposit not equal"
        );

        vm.stopPrank();

        // User1 withdraws 0.25 ether worth of shares
        vm.startPrank(user1);
        uint256 withdrawAmount = 0.25 ether;
        jitRebalancer.withdrawLiquidity(withdrawAmount, user1);
        console2.log(
            "User1 Token Balance After Withdraw",
            token0.balanceOf(user1)
        );
        console2.log(
            "User1 Token Balance After Withdraw",
            token1.balanceOf(user1)
        );
        console2.log(
            "JIT Balance After User1 Withdraw",
            jitRebalancer.balanceOf(user1)
        );

        // Check balances after withdrawal
        assertEq(
            jitRebalancer.balanceOf(user1), // 0.25
            0.25 ether,
            "Remaining shares not correct"
        );

        uint256 expectedToken0Balance = (jitRebalancer.totalDepositedToken0() *
            withdrawAmount) / jitRebalancer.totalSupply();
        uint256 expectedToken1Balance = (jitRebalancer.totalDepositedToken1() *
            withdrawAmount) / jitRebalancer.totalSupply();

        console2.log("JIT Expected Balance", expectedToken0Balance);
        console2.log("JIT Expected Balance", expectedToken1Balance);

        // Debugging logs
        console2.log(
            "Total Deposited Token0:",
            jitRebalancer.totalDepositedToken0()
        );
        console2.log(
            "Total Deposited Token1:",
            jitRebalancer.totalDepositedToken1()
        );

        console2.log("Total Supply:", jitRebalancer.totalSupply());
        console2.log("Actual Token0 Balance:", token0.balanceOf(user1));
        console2.log("Actual Token1 Balance:", token1.balanceOf(user1));

        // Verify user1's token balances after withdrawal
        assertApproxEqAbs(
            token0.balanceOf(user1),
            0.75 ether,
            1 wei,
            "Token0 withdrawal balance mismatch"
        );
        assertApproxEqAbs(
            token1.balanceOf(user1),
            0.75 ether,
            1 wei,
            "Token1 withdrawal balance mismatch"
        );

        vm.stopPrank();
    }

    function testMultipleDepositorsWithdrawLiquidity() public {
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = makeAddr("user3");

        for (uint256 i = 0; i < users.length; i++) {
            address currentUser = users[i];

            // Start prank for the current user
            vm.startPrank(currentUser);
            token0.mint(currentUser, 1 ether);
            token1.mint(currentUser, 1 ether);
            token0.approve(address(jitRebalancer), 1 ether);
            token1.approve(address(jitRebalancer), 1 ether);
            jitRebalancer.depositLiquidity(0.5 ether, 0.5 ether);

            console2.log(
                "currentUser Token0 Balance After Deposit",
                token0.balanceOf(currentUser)
            );
            console2.log(
                "currentUser Token0 Balance After Deposit",
                token0.balanceOf(currentUser)
            );
            console2.log(
                "JIT Balance After currentUser Deposit",
                jitRebalancer.balanceOf(currentUser)
            );

            assertEq(
                jitRebalancer.balanceOf(currentUser),
                0.5 ether,
                "deposit not equal"
            );
            vm.stopPrank();

            vm.startPrank(currentUser);
            uint256 withdrawAmount = 0.25 ether;
            jitRebalancer.withdrawLiquidity(withdrawAmount, user1);
            console2.log(
                "currentUser Token Balance After Withdraw",
                token0.balanceOf(user1)
            );
            console2.log(
                "currentUser Token Balance After Withdraw",
                token1.balanceOf(user1)
            );
            console2.log(
                "JIT Balance After currentUser Withdraw",
                jitRebalancer.balanceOf(user1)
            );

            assertEq(
                jitRebalancer.balanceOf(user1), // 0.25
                0.25 ether,
                "Remaining shares not correct"
            );
        }
    }

    function test_getPrice() public view {
        console2.log(jitRebalancer._getPrice());
    }
}
