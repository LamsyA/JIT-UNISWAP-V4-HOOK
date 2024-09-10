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

contract RouterHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    Quoter public quoter;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    mapping(address token0 => mapping(address token1 => address rebalancerAddress)) public deployedRebalancerAddress;
    int256 LARGE_SWAP_THRESHOLD = -1 ether;

    function rebalancerFactory(address _token0, address _token1) public returns (address) {
        address rebalance = deployedRebalancerAddress[_token0][_token1];
        require(rebalance == address(0), "JIT: Hook already deployed for pair");

        JITRebalancer jitRebalancer = new JITRebalancer(_token0, _token1, address(this));
        deployedRebalancerAddress[_token0][_token1] = address(jitRebalancer);
        return address(jitRebalancer);
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // Set the flag to indicate we're in a swap

        address jit = getFactoryAddress(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        require(jit != address(0), "pool doesnt exist for pair");

        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = poolManager.getLiquidity(key.toId());
        uint24 feePips = key.fee; // Retrieve the fee

        // Calculate target price for large swaps
        uint160 sqrtPriceTargetX96 = swapParams.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // Use computeSwapStep to get the next price, amounts, and fees
        (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceX96, sqrtPriceTargetX96, liquidity, swapParams.amountSpecified, feePips);

        // perform JIT
        if (LARGE_SWAP_THRESHOLD > swapParams.amountSpecified) {
            bool zeroForOne = swapParams.zeroForOne;
            // to get the direction of the swap....
            address token = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
            uint256 amount = absoluteValue(swapParams.amountSpecified);
            // withdraw token from pair pool....
            IERC20(token).transferFrom(jit, address(this), uint256(amount * 2));

            // Calculate the new tick after the swap......
            int24 newTick = TickMath.getTickAtSqrtPrice(sqrtPriceNextX96); //returns the higher tick range...
                // TickMath.getSqrtPriceAtTick(tick);
            int24 tickLower = getLowerUsableTick(newTick, key.tickSpacing);
            int24 tickUpper = tickLower + key.tickSpacing;
            int256 liquidity = int256(amount);
            // IERC20(token).approve(address(poolManager), type(uint256).max);
            // IERC20(Currency.unwrap(key.currency1)).approve(address(poolManager), type(uint256).max);
            poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: liquidity,
                    salt: 0
                }),
                hookData
            );
            // uint160  newSqrtPriceTargetX96=  TickMath.getSqrtPriceAtTick(tickUpper);

            // ( sqrtPriceNextX96,  amountIn,  amountOut,  feeAmount) =
            // SwapMath.computeSwapStep(sqrtPriceX96, newSqrtPriceTargetX96, poolManager.getLiquidity(key.toId()), swapParams.amountSpecified, feePips);
        }
        // Convert amounts to BeforeSwapDelta format
        int128 deltaSpecified = swapParams.zeroForOne ? int128(int256(amountIn)) : -int128(int256(amountIn));
        int128 deltaUnspecified = swapParams.zeroForOne ? -int128(int256(amountOut)) : int128(int256(amountOut));
        BeforeSwapDelta delta = toBeforeSwapDelta(deltaSpecified, deltaUnspecified);

        // get jit address to get liquidity from ...
        // get amount to be swapped if large enough then
        // get price tick the large swap would occur at
        // add liquidity to the price tick
        // revert HookNotImplemented();
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
