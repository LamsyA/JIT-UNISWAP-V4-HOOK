// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract JITRebalancer is ERC20 {
    IERC20 public token0;
    IERC20 public token1;

    uint256 public totalDeposited;
    address public pricefeed;

    constructor(address _token0, address _token1, address _routerHook, address _pricefeed) ERC20("JIT TOken", "JIT") {
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        pricefeed = _pricefeed;
        token0.approve(_routerHook, type(uint256).max);
        token1.approve(_routerHook, type(uint256).max);
    }

    // users deposit usdc and mint token based on deposit...
    // on withdrawal they can withdraw based on the shares of the pool
    // exampple user a deposit 1 wei
    // user b deposits 1 wei
    // totalminted is now 2 wei..
    // user a when withdrawing will be 50% of token 0 and 50% of token 1....

    function depositLiquidity(uint256 amount) public {
        require(amount > 0, "Must deposit more than 0");
        token0.transferFrom(msg.sender, address(this), amount);
        uint256 sharesToMint = calculateShares(amount);
        _mint(msg.sender, sharesToMint);
        totalDeposited += amount;
    }

    function calculateShares(uint256 amount) internal view returns (uint256) {
        if (totalSupply() == 0) {
            // Initial liquidity
            return amount;
        } else {
            // Proportional liquidity based on the amount of USDC relative to totalDeposited
            return (amount * totalSupply()) / totalDeposited;
        }
    }

    /// @notice Withdraw liquidity and receive token0 and token1 proportionally to pool shares
    function withdrawLiquidity(uint256 shareAmount,address withdrawTo) external {
        require(shareAmount > 0, "Must withdraw more than 0");
        require(balanceOf(msg.sender) >= shareAmount, "Insufficient balance");
        uint256 token0Amount = (token0.balanceOf(address(this)) * shareAmount) / totalSupply();
        uint256 token1Amount = (token1.balanceOf(address(this)) * shareAmount) / totalSupply();
        _burn(msg.sender, shareAmount);
        totalDeposited -= shareAmount;
        token0.transfer( withdrawTo, token0Amount);
        token1.transfer( withdrawTo, token1Amount);
    }

    /**
      * @notice Gets the price of the token.
      * @return The price of the token.
      */
    function _getPrice() public view returns (int256) {
        (, int256 price,,,)= AggregatorV3Interface(pricefeed).latestRoundData();
        int256 retunredPrice =  int256(price) / 1e8;
        return retunredPrice;
    }
}
