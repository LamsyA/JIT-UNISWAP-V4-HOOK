// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

abstract contract Utils is ERC20 {
    function calculateShares(
        uint256 amount0,
        uint256 amount1,
        uint256 totalDepositedToken0,
        uint256 totalDepositedToken1
    ) internal view returns (uint256) {
        if (totalSupply() == 0) {
            // Initial liquidity, return the geometric mean of the two amounts
            return sqrt(amount0 * amount1);
        } else {
            // Calculate shares proportional to both token0 and token1
            uint256 totalLiquidity = totalDepositedToken0 +
                totalDepositedToken1;
            uint256 totalDeposit = amount0 + amount1;
            return (totalDeposit * totalSupply()) / totalLiquidity;
        }
    }

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
