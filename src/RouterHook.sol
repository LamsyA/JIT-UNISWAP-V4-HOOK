// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {JITRebalancer} from "./JITRebalancer.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IQuoter} from "v4-periphery/src/interfaces/IQuoter.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Quoter} from "v4-periphery/src/lens/Quoter.sol";
import {SwapMath} from "v4-periphery/lib/v4-core/src/libraries/SwapMath.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "v4-periphery/lib/v4-core/test/utils/Constants.sol";

contract RouterHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    Quoter public quoter;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    mapping(address token0 => mapping(address token1 => address rebalancerAddress)) public deployedRebalancerAddress;
    uint256 LARGE_SWAP_THRESHOLD = 1 ether;

    function rebalancerFactory(address _token0, address _token1) public returns (address) {
        address rebalance = deployedRebalancerAddress[_token0][_token1];
        require(rebalance == address(0), "JIT: Hook already deployed for pair");

        JITRebalancer jitRebalancer = new JITRebalancer(_token0, _token1, address(this), address(0));
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
        int256 price = JITRebalancer(jit)._getPrice();

        uint tokenInUsd = uint256(swapParams.amountSpecified) * uint256(price);
        require(jit != address(0), "pool doesn't exist for pair");

        // Get the current price, tick, and liquidity from the pool
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = poolManager.getLiquidity(key.toId());
        uint24 feePips = key.fee; // Retrieve the fee

        // Set target price for the swap direction
        uint160 sqrtPriceTargetX96 = swapParams.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // Use computeSwapStep to get the next price, amounts, and fees
        (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) = SwapMath.computeSwapStep(
            sqrtPriceX96,
            sqrtPriceTargetX96,
            liquidity,
            adjustAmountSpecified(swapParams.zeroForOne, swapParams.amountSpecified),
            feePips
        );

        // for large swaps but will only work on testnet and mainnet in production
        // if (absoluteValue(int256(tokenInUsd)) > LARGE_SWAP_THRESHOLD) {
            // Handle JIT liquidity only for large swaps
        if (absoluteValue(int256(swapParams.amountSpecified)) > LARGE_SWAP_THRESHOLD) {
            bool zeroForOne = swapParams.zeroForOne;
            address token = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

            // Convert amountSpecified to absolute value to avoid negative amounts for JIT
            uint256 amount = absoluteValue(swapParams.amountSpecified);

            // Calculate new tick after swap
            int24 newTick = TickMath.getTickAtSqrtPrice(sqrtPriceNextX96); // Get the higher tick range

            // Ensure tick spacing for liquidity range
            int24 tickUpper = getLowerUsableTick(newTick, key.tickSpacing);
            int24 tickLower = tickUpper > 0 ? -tickUpper : tickUpper + tickUpper;

            // inrare cses when upper tick is min tick available do this
            if (tickLower < TickMath.MIN_TICK) {
                tickLower = getUpperUsableTick(newTick, key.tickSpacing);
                tickUpper = -tickLower;
            }

            // Get sqrt prices at the tick boundaries
            uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(tickUpper);

            // Calculate the liquidity amount to add
            uint128 liquidityDelta =
                LiquidityAmounts.getLiquidityForAmount0(sqrtPriceAtTickLower, sqrtPriceAtTickUpper, amount);

            uint256 amount1ToAdd =
                LiquidityAmounts.getAmount1ForLiquidity(sqrtPriceAtTickLower, sqrtPriceAtTickUpper, liquidityDelta);

            // Withdraw tokens from JIT address (pool) to contract
            IERC20(token).transferFrom(jit, address(this), amount1ToAdd);

            // Modify liquidity in the pool
            poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidityDelta)),
                    salt: 0
                }),
                hookData
            );
        }

        // Convert amounts to BeforeSwapDelta format (for exact input or output)
        int128 deltaSpecified = swapParams.zeroForOne ? int128(int256(amountIn)) : -int128(int256(amountIn));
        int128 deltaUnspecified = swapParams.zeroForOne ? -int128(int256(amountOut)) : int128(int256(amountOut));

        // Create the BeforeSwapDelta structure
        BeforeSwapDelta delta = toBeforeSwapDelta(deltaSpecified, deltaUnspecified);

        // Return the result
        return (this.beforeSwap.selector, delta, 0);
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

    function adjustAmountSpecified(bool zeroForOne, int256 amountSpecified) internal pure returns (int256) {
        if (zeroForOne) {
            if (amountSpecified > 0) {
                return amountSpecified;
            }
        } else {
            if (amountSpecified < 0) {
                return -amountSpecified;
            }
        }
        return amountSpecified;
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
            afterSwap: false,
            beforeDonate: false,
            afterDonate: true,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
