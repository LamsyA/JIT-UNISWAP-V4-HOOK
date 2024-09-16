// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../src/lib/Utils.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console2} from "forge-std/console2.sol";

contract JITRebalancer is ERC20, ReentrancyGuard, Utils {
    IERC20 public token0;
    IERC20 public token1;

    address public pricefeed;
    uint256 public totalDepositedToken0;
    uint256 public totalDepositedToken1;

    error DepositMustBeGreaterThanZero();
    error WithdrawalMustBeGreaterThanZero();
    error InsufficientBalance();
    error InvalidAddresses();
    error ZeroAddress();

    constructor(
        address _token0,
        address _token1,
        address _routerHook,
        address _pricefeed
    ) ERC20("JIT TOken", "JIT") {
        if (_token0 == _token1 || _routerHook == pricefeed)
            revert InvalidAddresses();
        if (_token0 == address(0) || _token1 == address(0))
            revert ZeroAddress();

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

    function depositLiquidity(uint256 amount0, uint256 amount1) public {
        require(amount0 > 0 && amount1 > 0, DepositMustBeGreaterThanZero());

        // Transfer tokens to the contract
        require(
            token0.transferFrom(msg.sender, address(this), amount0),
            "JIT: Transfer Failed"
        );
        require(
            token1.transferFrom(msg.sender, address(this), amount1),
            "JIT: Transfer Failed"
        );

        // Calculate shares to mint based on the proportional amount of both tokens
        uint256 sharesToMint = calculateShares(
            amount0,
            amount1,
            totalDepositedToken0,
            totalDepositedToken1
        );
        _mint(msg.sender, sharesToMint);

        // Update the total deposited amounts for both tokens
        totalDepositedToken0 += amount0;
        totalDepositedToken1 += amount1;
    }

    /// @notice Withdraw liquidity and receive token0 and token1 proportionally to pool shares
    function withdrawLiquidity(
        uint256 shareAmount,
        address withdrawTo
    ) external nonReentrant {
        require(shareAmount > 0, WithdrawalMustBeGreaterThanZero());
        require(balanceOf(msg.sender) >= shareAmount, InsufficientBalance());
        if (withdrawTo == address(0)) revert ZeroAddress();

        // Calculate amounts of token0 and token1 to withdraw
        uint256 token0Amount = (totalDepositedToken0 * shareAmount) /
            totalSupply();
        uint256 token1Amount = (totalDepositedToken1 * shareAmount) /
            totalSupply();

        // Burn the shares
        _burn(msg.sender, shareAmount);
        console2.log("Token amounts ::::", token0Amount, token1Amount);
        // Update total deposited amounts
        totalDepositedToken0 -= token0Amount;
        totalDepositedToken1 -= token1Amount;

        // Transfer tokens back to the user
        token0.transfer(withdrawTo, token0Amount);
        token1.transfer(withdrawTo, token1Amount);
    }

    /**
     * @notice Gets the price of the token.
     * @return The price of the token.
     */
    function _getPrice(address pricefeed) public view returns (int256) {
        (, int256 price, , , ) = AggregatorV3Interface(pricefeed)
            .latestRoundData();
        int256 retunredPrice = int256(price) / 1e8;
        return retunredPrice;
    }
}
