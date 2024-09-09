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

contract RouterHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IQuoter public quoter;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    mapping(address token0 => mapping(address token1 => address rebalancerAddress)) public deployedRebalancerAddress;
    int256 LARGE_SWAP_THRESHOLD = 1 ether;

    function rebalancerFactory(address _token0, address _token1) public {
        address rebalance = deployedRebalancerAddress[_token0][_token1];
        require(rebalance == address(0), "JIT: Hook already deployed for pair");

        JITRebalancer jitRebalancer = new JITRebalancer(_token0, _token1, address(this));
        deployedRebalancerAddress[_token0][_token1] = address(jitRebalancer);
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        address jit = getFactoryAddress(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        require(jit != address(0), "pool doesnt exist for pair");

        // (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        uint256 amountIn = uint256(swapParams.amountSpecified);
        bool zeroForOne = swapParams.zeroForOne;
        uint160 MAX_SLIPPAGE = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // precalculate price ....
        (int128[] memory deltaAmounts, uint160 sqrtPriceX96After,) = quoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams(key, zeroForOne, uint128(amountIn), MAX_SLIPPAGE, hookData)
        );

        // Interpret the delta amounts
        int128 deltaSpecified = deltaAmounts[0]; // Change in the amount of the specified token
        int128 deltaUnspecified = deltaAmounts[1]; // Change in the amount of the unspecified token

        // Create BeforeSwapDelta
        BeforeSwapDelta delta = toBeforeSwapDelta(deltaSpecified, deltaUnspecified);

        // perform JIT
        if (swapParams.amountSpecified > LARGE_SWAP_THRESHOLD) {
            // Calculate the new tick after the swap
            int24 newTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96After); //returns the higher tick range...

            int24 tickLower = newTick - key.tickSpacing;
            int24 tickUpper = newTick;
            int256 liquidity = LARGE_SWAP_THRESHOLD * 2;
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
        }
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

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
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
