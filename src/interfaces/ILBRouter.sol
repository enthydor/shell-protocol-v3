// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface ILBRouter {

    enum Version {
        V1,
        V2,
        V2_1
    }

    struct Path {
        uint256[] pairBinSteps;
        Version[] versions;
        IERC20[] tokenPath; 
    }

    function swapExactTokensForTokens(
            uint256 amountIn,
            uint256 amountOutMin,
            Path memory path,
            address to,
            uint256 deadline
    ) external returns (uint256 amountOut);

}