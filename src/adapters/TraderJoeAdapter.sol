// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ILBPair} from "../interfaces/ILBPair.sol";
import {ILBQuoter} from "../interfaces/ILBQuoter.sol";
import "./OceanAdapter.sol";
import "../interfaces/ILBRouter.sol";


enum ComputeType {
    Swap
}

contract TraderJoeAdapter is OceanAdapter {
    /////////////////////////////////////////////////////////////////////
    //                             Errors                              //
    /////////////////////////////////////////////////////////////////////
    error INVALID_COMPUTE_TYPE();
    error SLIPPAGE_LIMIT_EXCEEDED();

    /////////////////////////////////////////////////////////////////////
    //                             Events                              //
    /////////////////////////////////////////////////////////////////////
    event Swap(
        uint256 inputToken, 
        uint256 inputAmount, 
        uint256 outputAmount, 
        bytes32 slippageProtection, 
        address user, 
        bool computeOutput
    );

    /// @notice x token Ocean ID.
    uint256 public immutable xToken;

    /// @notice y token Ocean ID.
    uint256 public immutable yToken;

    /// @notice TraderJoe router
    ILBRouter public immutable router;

    /// @notice Quoter contract
    ILBQuoter public immutable quoter;

    /////////////////////////////////////////////////////////////////////
    //                           Constructor                           //
    /////////////////////////////////////////////////////////////////////

    /**
     * @notice only initializing the immutables, mappings & approves tokens
     */
    constructor(
        address ocean_, 
        address primitive_, 
        ILBRouter router_, 
        ILBQuoter quoter_
    ) OceanAdapter(ocean_, primitive_) {
        router = router_;
        quoter = quoter_;
        
        ILBPair pool = ILBPair(primitive_);

        address xTokenAddress = address(pool.getTokenX());
        xToken = _calculateOceanId(xTokenAddress, 0);
        underlying[xToken] = xTokenAddress;
        decimals[xToken] = IERC20Metadata(xTokenAddress).decimals();
        _approveToken(xTokenAddress);

        address yTokenAddress = address(pool.getTokenY());
        yToken = _calculateOceanId(yTokenAddress, 0);
        underlying[yToken] = yTokenAddress;
        decimals[yToken] = IERC20Metadata(yTokenAddress).decimals();
        _approveToken(yTokenAddress);
    }

    /**
     * @dev wraps the underlying token into the Ocean
     * @param tokenId Ocean ID of token to wrap
     * @param amount wrap amount
     */
    function wrapToken(uint256 tokenId, uint256 amount, bytes32 metadata) internal override {
        address tokenAddress = underlying[tokenId];

        Interaction memory interaction = Interaction({
            interactionTypeAndAddress: _fetchInteractionId(tokenAddress, uint256(InteractionType.WrapErc20)), 
            inputToken: 0, 
            outputToken: 0, 
            specifiedAmount: amount, 
            metadata: bytes32(0) 
        });

        IOceanInteractions(ocean).doInteraction(interaction);
    }

    /**
     * @dev unwraps the underlying token from the Ocean
     * @param tokenId Ocean ID of token to unwrap
     * @param amount unwrap amount
     */
    function unwrapToken(uint256 tokenId, uint256 amount, bytes32 metadata) internal override returns (uint256 unwrappedAmount) {
        address tokenAddress = underlying[tokenId];

        Interaction memory interaction = Interaction({ 
            interactionTypeAndAddress: _fetchInteractionId(tokenAddress, uint256(InteractionType.UnwrapErc20)), 
            inputToken: 0, 
            outputToken: 0, 
            specifiedAmount: amount, 
            metadata: bytes32(0) 
        });

        IOceanInteractions(ocean).doInteraction(interaction);

        // handle the unwrap fee scenario
        uint256 unwrapFee = amount / IOceanInteractions(ocean).unwrapFeeDivisor();
        (, uint256 truncated) = _convertDecimals(NORMALIZED_DECIMALS, decimals[tokenId], amount - unwrapFee);
        unwrapFee = unwrapFee + truncated;

        unwrappedAmount = amount - unwrapFee;
    }

    /**
     * @dev swaps from TraderJoe's Pools
     * @param inputToken The user is giving this token to the pool
     * @param outputToken The pool is giving this token to the user
     * @param inputAmount The amount of the inputToken the user is giving to the pool
     * @param minimumOutputAmount The minimum amount of tokens expected back after the exchange
     */
    function primitiveOutputAmount(
        uint256 inputToken, 
        uint256 outputToken, 
        uint256 inputAmount, 
        bytes32 minimumOutputAmount
    ) internal override returns (uint256 outputAmount) {
        bool isX = inputToken == xToken;

        (uint256 rawInputAmount,) = _convertDecimals(NORMALIZED_DECIMALS, decimals[inputToken], inputAmount);

        _determineComputeType(inputToken, outputToken);

        // Set swap route
        address[] memory route = new address[](2);
        if (isX) {
            route[0] = underlying[inputToken];
            route[1] = underlying[outputToken];
        } else {
            route[0] = underlying[outputToken];
            route[1] = underlying[inputToken];
        }

        // Find the best path for swap
        ILBQuoter.Quote memory quote = quoter.findBestPathFromAmountIn(route, uint128(rawInputAmount));

        IERC20[] memory tokenPath = new IERC20[](quote.route.length);
        for (uint256 i = 0;  i < quote.route.length; i++) {
            tokenPath[i] = IERC20(quote.route[i]);
        }

        ILBRouter.Path memory path = ILBRouter.Path({
            pairBinSteps: quote.binSteps,
            versions: quote.versions,
            tokenPath: tokenPath
        });

        uint256 amountOut = router.swapExactTokensForTokens(
            rawInputAmount,
            0, 
            path, 
            address(this), 
            block.timestamp + 1
        );

        (outputAmount,) = _convertDecimals(decimals[outputToken], NORMALIZED_DECIMALS, amountOut);

        if (uint256(minimumOutputAmount) > outputAmount) revert SLIPPAGE_LIMIT_EXCEEDED();

        emit Swap(inputToken, inputAmount, outputAmount, minimumOutputAmount, primitive, true);
    }

    /**
     * @dev Approves token to be spent by the Ocean and the TraderJoe pool
     */
    function _approveToken(address tokenAddress) private {
        IERC20Metadata(tokenAddress).approve(ocean, type(uint256).max);
        IERC20Metadata(tokenAddress).approve(address(router), type(uint256).max);
    }

    /**
     * @dev Uses the inputToken and outputToken to determine the ComputeType
     *  (input: xToken, output: yToken) | (input: yToken, output: xToken) => SWAP
     *  base := xToken | yToken
     *  (input: base, output: lpToken) => DEPOSIT
     *  (input: lpToken, output: base) => WITHDRAW
     */
    function _determineComputeType(
        uint256 inputToken, 
        uint256 outputToken
    ) private view returns (ComputeType computeType) {
        if (((inputToken == xToken) && (outputToken == yToken)) || ((inputToken == yToken) && (outputToken == xToken))) {
            return ComputeType.Swap;
        } else {
            revert INVALID_COMPUTE_TYPE();
        }
    }

    receive() external payable { }
}
