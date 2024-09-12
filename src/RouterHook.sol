// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {JITRebalancer} from "./JITRebalancer.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IQuoter} from "v4-periphery/src/interfaces/IQuoter.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapMath} from "v4-periphery/lib/v4-core/src/libraries/SwapMath.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "v4-periphery/lib/v4-core/test/utils/Constants.sol";

import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {console2} from "forge-std/console2.sol";

contract RouterHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;

    int256 price;

    int24 tickUpper;
    int24 tickLower;
    uint128 liquidityDelta;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    mapping(address token0 => mapping(address token1 => address rebalancerAddress)) public deployedRebalancerAddress;
    uint256 private constant LARGE_SWAP_THRESHOLD = 1e7;
    uint256 private constant SWAP_BALANCER = 1e18;

    error HookAlreadyDeployedForPair();
    error PoolDoesnotExistForPair();

    function rebalancerFactory(address _token0, address _token1, address _priceFeed) public returns (address) {
        address rebalance = deployedRebalancerAddress[_token0][_token1];
        address reverseBalance = deployedRebalancerAddress[_token1][_token0];
        require(rebalance == address(0) && reverseBalance == address(0), HookAlreadyDeployedForPair());

        JITRebalancer jitRebalancer = new JITRebalancer(_token0, _token1, address(this), _priceFeed);
        deployedRebalancerAddress[_token0][_token1] = address(jitRebalancer);
        IERC20(_token0).approve(address(poolManager), type(uint256).max);
        IERC20(_token1).approve(address(poolManager), type(uint256).max);

        return address(jitRebalancer);
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        address jit = getFactoryAddress(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        price = JITRebalancer(jit)._getPrice();
        console2.log(
            " Jit Price Feed for the Token ", absoluteValue(swapParams.amountSpecified * price) / SWAP_BALANCER
        );

        uint256 tokenInUsd = absoluteValue(swapParams.amountSpecified * price) / SWAP_BALANCER;
        require(jit != address(0), PoolDoesnotExistForPair());

        // Get the current price, tick, and liquidity from the pool
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = poolManager.getLiquidity(key.toId());
        uint24 feePips = key.fee; // Retrieve the fee

        // Set target price for the swap direction
        uint160 sqrtPriceTargetX96 = swapParams.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // Use computeSwapStep to get the next price, amounts, and fees
        (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut,) =
            SwapMath.computeSwapStep(sqrtPriceX96, sqrtPriceTargetX96, liquidity, swapParams.amountSpecified, feePips);

        // Handle JIT liquidity only for large swaps
        if (tokenInUsd > LARGE_SWAP_THRESHOLD) {
            // Convert amountSpecified to absolute value to avoid negative amounts for JIT
            uint256 amount = absoluteValue(swapParams.amountSpecified);

            // Calculate new tick after swap
            int24 newTick = TickMath.getTickAtSqrtPrice(sqrtPriceNextX96); // Get the higher tick range

            // Ensure tick spacing for liquidity range
            tickUpper = getLowerUsableTick(newTick, key.tickSpacing);
            tickLower = tickUpper > 0 ? -tickUpper : tickUpper + tickUpper;

            // inrare cses when upper tick is min tick available do this
            // if (tickLower < TickMath.MIN_TICK) {
            //     tickLower = getUpperUsableTick(newTick, key.tickSpacing);
            //     tickUpper = -tickLower;
            // }

            // Get sqrt prices at the tick boundaries
            uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(tickUpper);

            // Calculate the liquidity amount to add
            liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceAtTickLower, sqrtPriceAtTickUpper, amount);

            // uint256 amount1ToAdd =
            //     LiquidityAmounts.getAmount1ForLiquidity(sqrtPriceAtTickLower, sqrtPriceAtTickUpper, liquidityDelta);

            // Modify liquidity in the pool
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidityDelta)),
                    salt: 0
                }),
                hookData
            );

            int256 delta0 = delta.amount0();
            int256 delta1 = delta.amount1();
            if (delta0 < 0) {
                // Withdraw tokens from JIT address (pool) to contract
                IERC20(Currency.unwrap(key.currency0)).transferFrom(jit, address(this), uint256(-delta0));
                key.currency0.settle(poolManager, address(this), uint256(-delta0), false);
            }
            if (delta1 < 0) {
                IERC20(Currency.unwrap(key.currency1)).transferFrom(jit, address(this), uint256(-delta1));
                key.currency1.settle(poolManager, address(this), uint256(-delta1), false);
            }
        }

        // Convert amounts to BeforeSwapDelta format (for exact input or output)
        int128 deltaSpecified = swapParams.zeroForOne ? int128(int256(amountIn)) : -int128(int256(amountIn));
        int128 deltaUnspecified = swapParams.zeroForOne ? -int128(int256(amountOut)) : int128(int256(amountOut));

        // Create the BeforeSwapDelta structure
        BeforeSwapDelta deltas = toBeforeSwapDelta(deltaSpecified, deltaUnspecified);

        // Return the result
        return (this.beforeSwap.selector, deltas, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external override returns (bytes4, int128) {
        address jit = getFactoryAddress(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));

        uint256 tokenInUsd = absoluteValue(params.amountSpecified * price) / SWAP_BALANCER;

        if (tokenInUsd > LARGE_SWAP_THRESHOLD) {
            (BalanceDelta _delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(uint256(liquidityDelta)),
                    salt: 0
                }),
                data
            );
            int256 delta0 = _delta.amount0();
            int256 delta1 = _delta.amount1();

            if (delta0 > 0) key.currency0.take(poolManager, jit, uint256(delta0), false);
            if (delta1 > 0) key.currency1.take(poolManager, jit, uint256(delta1), false);
        }
        return (this.afterSwap.selector, 0);
    }

    function getFactoryAddress(address _token0, address _token1) public view returns (address) {
        address rebalance = deployedRebalancerAddress[_token0][_token1];
        return rebalance;
    }

    function absoluteValue(int256 value) internal pure returns (uint256) {
        return value >= 0 ? uint256(value) : uint256(-value);
    }

    function getLowerUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity
        return intervals * tickSpacing;
    }

    function getUpperUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        // If the tick is not perfectly aligned, move up to the next interval
        if (tick % tickSpacing != 0) {
            intervals++;
        }
        return intervals * tickSpacing;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
