// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {Constants} from "./libraries/Constants.sol";
import {JoeLibrary} from "./libraries/JoeLibrary.sol";
import {PriceHelper} from "./libraries/PriceHelper.sol";
import {Uint256x256Math} from "./libraries/math/Uint256x256Math.sol";
import {SafeCast} from "./libraries/math/SafeCast.sol";

import {ILBFactory, ILBPair} from "./interfaces/ILBPairFactory.sol";
import {ILBRouter} from "./interfaces/ILBRouter.sol";

/**
 * @title Liquidity Book Quoter
 * @author Trader Joe
 * @notice Helper contract to determine best path through multiple markets
 */
contract LBQuoterV2_1 {
    using Uint256x256Math for uint256;
    using SafeCast for uint256;

    error LBQuoter_InvalidLength();

    address private immutable _factoryV2;
    address private immutable _routerV2;

    /**
     * @dev The quote struct returned by the quoter
     * - route: address array of the token to go through
     * - pairs: address array of the pairs to go through
     * - binSteps: The bin step to use for each pair
     * - versions: The version to use for each pair
     * - amounts: The amounts of every step of the swap
     * - virtualAmountsWithoutSlippage: The virtual amounts of every step of the swap without slippage
     * - fees: The fees to pay for every step of the swap
     */
    struct Quote {
        address[] route;
        address[] pairs;
        uint256[] binSteps;
        ILBRouter.Version[] versions;
        uint128[] amounts;
        uint128[] virtualAmountsWithoutSlippage;
        uint128[] fees;
    }

    /**
     * @notice Constructor
     * @param factoryV2 Dex V2.1 factory address
     * @param routerV2 Dex V2 router address
     */
    constructor(address factoryV2, address routerV2) {
        _factoryV2 = factoryV2;
        _routerV2 = routerV2;
    }

    /**
     * @notice Returns the Dex V2.1 factory address
     * @return factoryV2 Dex V2.1 factory address
     */
    function getFactoryV2() public view returns (address factoryV2) {
        factoryV2 = _factoryV2;
    }

    /**
     * @notice Returns the Dex V2 router address
     * @return routerV2 Dex V2 router address
     */
    function getRouterV2() public view returns (address routerV2) {
        routerV2 = _routerV2;
    }

    /**
     * @notice Finds the best path given a list of tokens and the input amount wanted from the swap
     * @param route List of the tokens to go through
     * @param amountIn Swap amount in
     * @return quote The Quote structure containing the necessary element to perform the swap
     */
    function findBestPathFromAmountIn(
        address[] calldata route,
        uint128 amountIn
    ) public view returns (Quote memory quote) {
        if (route.length < 2) {
            revert LBQuoter_InvalidLength();
        }

        quote.route = route;

        uint256 swapLength = route.length - 1;
        quote.pairs = new address[](swapLength);
        quote.binSteps = new uint256[](swapLength);
        quote.versions = new ILBRouter.Version[](swapLength);
        quote.fees = new uint128[](swapLength);
        quote.amounts = new uint128[](route.length);
        quote.virtualAmountsWithoutSlippage = new uint128[](route.length);

        quote.amounts[0] = amountIn;
        quote.virtualAmountsWithoutSlippage[0] = amountIn;

        for (uint256 i; i < swapLength; i++) {
            // Fetch swaps for V2.1
            ILBFactory.LBPairInformation[] memory LBPairsAvailable = ILBFactory(_factoryV2).getAllLBPairs(
                IERC20(route[i]),
                IERC20(route[i + 1])
            );

            if (LBPairsAvailable.length > 0 && quote.amounts[i] > 0) {
                for (uint256 j; j < LBPairsAvailable.length; j++) {
                    if (!LBPairsAvailable[j].ignoredForRouting) {
                        bool swapForY = address(LBPairsAvailable[j].LBPair.getTokenY()) == route[i + 1];

                        try
                            ILBRouter(_routerV2).getSwapOut(LBPairsAvailable[j].LBPair, quote.amounts[i], swapForY)
                        returns (uint128 amountInLeft, uint128 swapAmountOut, uint128 fees) {
                            if (amountInLeft == 0 && swapAmountOut > quote.amounts[i + 1]) {
                                quote.amounts[i + 1] = swapAmountOut;
                                quote.pairs[i] = address(LBPairsAvailable[j].LBPair);
                                quote.binSteps[i] = uint16(LBPairsAvailable[j].binStep);
                                quote.versions[i] = ILBRouter.Version.V2_1;

                                // Getting current price
                                uint24 activeId = LBPairsAvailable[j].LBPair.getActiveId();
                                quote.virtualAmountsWithoutSlippage[i + 1] = _getV2Quote(
                                    quote.virtualAmountsWithoutSlippage[i] - fees,
                                    activeId,
                                    quote.binSteps[i],
                                    swapForY
                                );

                                quote.fees[i] = ((uint256(fees) * 1e18) / quote.amounts[i]).safe128(); // fee percentage in amountIn
                            }
                        } catch {}
                    }
                }
            }
        }
    }

    /**
     * @notice Finds the best path given a list of tokens and the output amount wanted from the swap
     * @param route List of the tokens to go through
     * @param amountOut Swap amount out
     * @return quote The Quote structure containing the necessary element to perform the swap
     */
    function findBestPathFromAmountOut(
        address[] calldata route,
        uint128 amountOut
    ) public view returns (Quote memory quote) {
        if (route.length < 2) {
            revert LBQuoter_InvalidLength();
        }
        quote.route = route;

        uint256 swapLength = route.length - 1;
        quote.pairs = new address[](swapLength);
        quote.binSteps = new uint256[](swapLength);
        quote.versions = new ILBRouter.Version[](swapLength);
        quote.fees = new uint128[](swapLength);
        quote.amounts = new uint128[](route.length);
        quote.virtualAmountsWithoutSlippage = new uint128[](route.length);

        quote.amounts[swapLength] = amountOut;
        quote.virtualAmountsWithoutSlippage[swapLength] = amountOut;

        for (uint256 i = swapLength; i > 0; i--) {
            // Fetch swaps for V2.1
            ILBFactory.LBPairInformation[] memory LBPairsAvailable;

            LBPairsAvailable = ILBFactory(_factoryV2).getAllLBPairs(IERC20(route[i - 1]), IERC20(route[i]));

            if (LBPairsAvailable.length > 0 && quote.amounts[i] > 0) {
                for (uint256 j; j < LBPairsAvailable.length; j++) {
                    if (!LBPairsAvailable[j].ignoredForRouting) {
                        bool swapForY = address(LBPairsAvailable[j].LBPair.getTokenY()) == route[i];
                        try
                            ILBRouter(_routerV2).getSwapIn(LBPairsAvailable[j].LBPair, quote.amounts[i], swapForY)
                        returns (uint128 swapAmountIn, uint128 amountOutLeft, uint128 fees) {
                            if (
                                amountOutLeft == 0 &&
                                swapAmountIn != 0 &&
                                (swapAmountIn < quote.amounts[i - 1] || quote.amounts[i - 1] == 0)
                            ) {
                                quote.amounts[i - 1] = swapAmountIn;
                                quote.pairs[i - 1] = address(LBPairsAvailable[j].LBPair);
                                quote.binSteps[i - 1] = uint16(LBPairsAvailable[j].binStep);
                                quote.versions[i - 1] = ILBRouter.Version.V2_1;

                                // Getting current price
                                uint24 activeId = LBPairsAvailable[j].LBPair.getActiveId();
                                quote.virtualAmountsWithoutSlippage[i - 1] =
                                    _getV2Quote(
                                        quote.virtualAmountsWithoutSlippage[i],
                                        activeId,
                                        quote.binSteps[i - 1],
                                        !swapForY
                                    ) +
                                    fees;

                                quote.fees[i - 1] = ((uint256(fees) * 1e18) / quote.amounts[i - 1]).safe128(); // fee percentage in amountIn
                            }
                        } catch {}
                    }
                }
            }
        }
    }

    /**
     * @dev Calculates a quote for a V2 pair
     * @param amount Amount in to consider
     * @param activeId Current active Id of the considred pair
     * @param binStep Bin step of the considered pair
     * @param swapForY Boolean describing if we are swapping from X to Y or the opposite
     * @return quote Amount Out if _amount was swapped with no slippage and no fees
     */
    function _getV2Quote(
        uint256 amount,
        uint24 activeId,
        uint256 binStep,
        bool swapForY
    ) internal pure returns (uint128 quote) {
        if (swapForY) {
            quote = PriceHelper
                .getPriceFromId(activeId, uint16(binStep))
                .mulShiftRoundDown(amount, Constants.SCALE_OFFSET)
                .safe128();
        } else {
            quote = amount
                .shiftDivRoundDown(Constants.SCALE_OFFSET, PriceHelper.getPriceFromId(activeId, uint16(binStep)))
                .safe128();
        }
    }
}
