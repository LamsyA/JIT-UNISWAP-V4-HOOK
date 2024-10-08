// SPDX-License-Identifier: MITrebalance
pragma solidity ^0.8.20;

import {Test, console2, console} from "forge-std/Test.sol";
import {JITRebalancer} from "../src/JITRebalancer.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {HelperConfig} from "../script/HelperConfig.sol";

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Constants} from "v4-periphery/lib/v4-core/test/utils/Constants.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IQuoter} from "v4-periphery/src/interfaces/IQuoter.sol";
import {Quoter} from "v4-periphery/src/lens/Quoter.sol";

// our contracts
import {RouterHook} from "../src/RouterHook.sol";

contract RouterHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency token0;
    Currency token1;
    address priceFeed;

    RouterHook routerHook;
    Quoter public quoter;
    address pairPool;

    event NewBalanceDelta(int128 delta0, int128 delta1);

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();
        HelperConfig aggregatorPriceFeed = new HelperConfig();
        (address wethUsdPriceFeed,,) = aggregatorPriceFeed.activeNetworkConfig();
        priceFeed = wethUsdPriceFeed;
        quoter = new Quoter(manager);
        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();
        // Deploy our hook
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG); //Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("RouterHook.sol", abi.encode(manager, ""), hookAddress);
        routerHook = RouterHook(hookAddress);

        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(address(routerHook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(routerHook), type(uint256).max);
        // MockERC20(Currency.unwrap(token1)).mint(address(manager), 10104739994504904353);

        // Initialize a pool with these two tokens
        (key,) = initPool(token0, token1, routerHook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        // Add initial liquidity to the pool

        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_router_can_factory_and_mint_tokens() public {
        pairPool = routerHook.rebalancerFactory(Currency.unwrap(token0), Currency.unwrap(token1), priceFeed);
        address expectedPairPool = routerHook.getFactoryAddress(Currency.unwrap(token0), Currency.unwrap(token1));
        assertEq(pairPool, expectedPairPool);
        console2.log("pair address", pairPool);

        MockERC20(Currency.unwrap(token0)).mint(pairPool, 100_000 ether);
        MockERC20(Currency.unwrap(token1)).mint(pairPool, 100_000 ether);

        assertEq(MockERC20(Currency.unwrap(token0)).balanceOf(pairPool), 100000 ether);
        assertEq(MockERC20(Currency.unwrap(token1)).balanceOf(pairPool), 100000 ether);
    }

    function test_add_liquidity_before_swap_zeroForOne_true() public {
        test_router_can_factory_and_mint_tokens();
        uint160 ticks = TickMath.getSqrtPriceAtTick(180);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -10000 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        // console2.log("key", key);

        console2.log("before JIT balance for token 0", MockERC20(Currency.unwrap(token0)).balanceOf(pairPool));
        console2.log("before JIT balance for token 1", MockERC20(Currency.unwrap(token1)).balanceOf(pairPool));
        uint256 balanceBeforeForTokenZero = MockERC20(Currency.unwrap(token0)).balanceOf(pairPool);
        uint256 balanceBeforeForTokenOne = MockERC20(Currency.unwrap(token1)).balanceOf(pairPool);
        BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        emit NewBalanceDelta(delta.amount0(), delta.amount1());
        // assertLt(MockERC20(Currency.unwrap(token1)).balanceOf(pairPool), 100000 ether);
        uint256 balanceAfterForTokenOne = MockERC20(Currency.unwrap(token1)).balanceOf(pairPool);
        uint256 balanceAfterForTokenZero = MockERC20(Currency.unwrap(token0)).balanceOf(pairPool);

        console2.log("After JIT balance for token 0", MockERC20(Currency.unwrap(token0)).balanceOf(pairPool));
        console2.log("After JIT balance for token 1", MockERC20(Currency.unwrap(token1)).balanceOf(pairPool));

        assertGt(balanceAfterForTokenZero, balanceBeforeForTokenZero);
        assertGt(balanceBeforeForTokenOne, balanceAfterForTokenOne);
    }

    function test_add_liquidity_before_swapzeroForOne_false() public {
        test_router_can_factory_and_mint_tokens();
        uint160 ticks = TickMath.getSqrtPriceAtTick(180);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -10000 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        console2.log("before JIT balance for token 0", MockERC20(Currency.unwrap(token0)).balanceOf(pairPool));
        console2.log("before JIT balance for token 1", MockERC20(Currency.unwrap(token1)).balanceOf(pairPool));
        uint256 balanceBeforeForTokenZero = MockERC20(Currency.unwrap(token0)).balanceOf(pairPool);
        uint256 balanceBeforeForTokenOne = MockERC20(Currency.unwrap(token1)).balanceOf(pairPool);
        BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        emit NewBalanceDelta(delta.amount0(), delta.amount1());
        // assertLt(MockERC20(Currency.unwrap(token1)).balanceOf(pairPool), 100000 ether);
        uint256 balanceAfterForTokenOne = MockERC20(Currency.unwrap(token1)).balanceOf(pairPool);
        uint256 balanceAfterForTokenZero = MockERC20(Currency.unwrap(token0)).balanceOf(pairPool);

        console2.log("After JIT balance for token 0", MockERC20(Currency.unwrap(token0)).balanceOf(pairPool));
        console2.log("After JIT balance for token 1", MockERC20(Currency.unwrap(token1)).balanceOf(pairPool));

        assertGt(balanceBeforeForTokenZero, balanceAfterForTokenZero);
        assertGt(balanceAfterForTokenOne, balanceBeforeForTokenOne);
    }

    function test_before_swap_with_lower_liquidity_needed_for_jit_zeroForOne_true() public {
        test_router_can_factory_and_mint_tokens();
        uint160 ticks = TickMath.getSqrtPriceAtTick(180);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.2 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        // console2.log("key", key);

        console2.log("before JIT balance for token 0", MockERC20(Currency.unwrap(token0)).balanceOf(pairPool));
        console2.log("before JIT balance for token 1", MockERC20(Currency.unwrap(token1)).balanceOf(pairPool));
        uint256 balanceBeforeForTokenZero = MockERC20(Currency.unwrap(token0)).balanceOf(pairPool);
        uint256 balanceBeforeForTokenOne = MockERC20(Currency.unwrap(token1)).balanceOf(pairPool);
        BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        emit NewBalanceDelta(delta.amount0(), delta.amount1());
        // assertLt(MockERC20(Currency.unwrap(token1)).balanceOf(pairPool), 100000 ether);
        uint256 balanceAfterForTokenOne = MockERC20(Currency.unwrap(token1)).balanceOf(pairPool);
        uint256 balanceAfterForTokenZero = MockERC20(Currency.unwrap(token0)).balanceOf(pairPool);

        console2.log("After JIT balance for token 0", MockERC20(Currency.unwrap(token0)).balanceOf(pairPool));
        console2.log("After JIT balance for token 1", MockERC20(Currency.unwrap(token1)).balanceOf(pairPool));

        assertEq(balanceBeforeForTokenZero, balanceAfterForTokenZero);
        assertEq(balanceAfterForTokenOne, balanceBeforeForTokenOne);
    }

    function test_before_swap_with_lower_liquidity_needed_for_jit_zeroForOne_false() public {
        test_router_can_factory_and_mint_tokens();
        uint160 ticks = TickMath.getSqrtPriceAtTick(180);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.2 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        // console2.log("key", key);
        console2.log("before JIT balance for token 0", MockERC20(Currency.unwrap(token0)).balanceOf(pairPool));
        console2.log("before JIT balance for token 1", MockERC20(Currency.unwrap(token1)).balanceOf(pairPool));
        uint256 balanceBeforeForTokenZero = MockERC20(Currency.unwrap(token0)).balanceOf(pairPool);
        uint256 balanceBeforeForTokenOne = MockERC20(Currency.unwrap(token1)).balanceOf(pairPool);
        BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        emit NewBalanceDelta(delta.amount0(), delta.amount1());
        // assertLt(MockERC20(Currency.unwrap(token1)).balanceOf(pairPool), 100000 ether);
        uint256 balanceAfterForTokenOne = MockERC20(Currency.unwrap(token1)).balanceOf(pairPool);
        uint256 balanceAfterForTokenZero = MockERC20(Currency.unwrap(token0)).balanceOf(pairPool);

        console2.log("After JIT balance for token 0", MockERC20(Currency.unwrap(token0)).balanceOf(pairPool));
        console2.log("After JIT balance for token 1", MockERC20(Currency.unwrap(token1)).balanceOf(pairPool));

        assertEq(balanceBeforeForTokenZero, balanceAfterForTokenZero);
        assertEq(balanceAfterForTokenOne, balanceBeforeForTokenOne);
    }
}
