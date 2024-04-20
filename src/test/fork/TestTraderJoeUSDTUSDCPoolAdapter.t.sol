pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";
import "../../interfaces/Interactions.sol";
import "../../ocean/Ocean.sol";
import "../../adapters/TraderJoeAdapter.sol";

contract TestTraderJoeUSDTUSDCPoolAdapter is Test {
    Ocean ocean;
    TraderJoeAdapter adapter;
    address wallet = 0x62383739D68Dd0F844103Db8dFb05a7EdED5BBE6; // Address with large USDT & USDC balance
    address usdt = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address pool = 0xFC43aAF89A71AcAa644842EE4219E8eB77657427; // USDT-USDC LBPool
    ILBRouter router = ILBRouter(0xb4315e873dBcf96Ffd0acd8EA43f689D8c20fB30);
    ILBQuoter quoter = ILBQuoter(0xd76019A16606FDa4651f636D9751f500Ed776250);

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc"); // Will start on latest block by default
        vm.prank(wallet);
        ocean = new Ocean("");
        adapter = new TraderJoeAdapter(
            address(ocean), 
            pool, 
            router, 
            quoter
        );
    }

    function testSwap(bool toggle, uint256 amount, uint256 unwrapFee) public {
        vm.startPrank(wallet);
        unwrapFee = bound(unwrapFee, 2000, type(uint256).max);
        ocean.changeUnwrapFee(unwrapFee);

        address inputAddress;
        address outputAddress;

        if (toggle) {
            inputAddress = usdt;
            outputAddress = usdc;
        } else {
            inputAddress = usdc;
            outputAddress = usdt;
        }

        // taking decimals into account
        amount = bound(amount, 1e17, IERC20(inputAddress).balanceOf(wallet) * 1e11);

        IERC20(inputAddress).approve(address(ocean), amount);

        uint256 prevInputBalance = IERC20(inputAddress).balanceOf(wallet);
        uint256 prevOutputBalance = IERC20(outputAddress).balanceOf(wallet);

        Interaction[] memory interactions = new Interaction[](3);

        interactions[0] = Interaction({ 
            interactionTypeAndAddress: _fetchInteractionId(inputAddress, uint256(InteractionType.WrapErc20)), 
            inputToken: 0, 
            outputToken: 0, 
            specifiedAmount: amount, 
            metadata: bytes32(0) 
        });

        interactions[1] = Interaction({
            interactionTypeAndAddress: _fetchInteractionId(address(adapter), uint256(InteractionType.ComputeOutputAmount)),
            inputToken: _calculateOceanId(inputAddress),
            outputToken: _calculateOceanId(outputAddress),
            specifiedAmount: type(uint256).max,
            metadata: bytes32(0)
        });

        interactions[2] = Interaction({ 
            interactionTypeAndAddress: _fetchInteractionId(outputAddress, uint256(InteractionType.UnwrapErc20)), 
            inputToken: 0, 
            outputToken: 0, 
            specifiedAmount: type(uint256).max, 
            metadata: bytes32(0) 
        });

        // erc1155 token id's for balance delta
        uint256[] memory ids = new uint256[](2);
        ids[0] = _calculateOceanId(inputAddress);
        ids[1] = _calculateOceanId(outputAddress);

        ocean.doMultipleInteractions(interactions, ids);

        uint256 newInputBalance = IERC20(inputAddress).balanceOf(wallet);
        uint256 newOutputBalance = IERC20(outputAddress).balanceOf(wallet);

        assertLt(newInputBalance, prevInputBalance);
        assertGt(newOutputBalance, prevOutputBalance);

        vm.stopPrank();
    }

    function _calculateOceanId(address tokenAddress) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(tokenAddress, uint256(0))));
    }

    function _fetchInteractionId(address token, uint256 interactionType) internal pure returns (bytes32) {
        uint256 packedValue = uint256(uint160(token));
        packedValue |= interactionType << 248;
        return bytes32(abi.encode(packedValue));
    }
}