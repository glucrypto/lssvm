// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LSSVMPair} from "./LSSVMPair.sol";
import {LSSVMPairFactoryLike} from "./LSSVMPairFactoryLike.sol";

contract LSSVMRouter {
    using Address for address payable;
    using SafeERC20 for IERC20;

    bytes1 private constant NFT_TRANSFER_START = 0x11;

    struct PairSwapAny {
        LSSVMPair pair;
        uint256 numItems;
    }

    struct PairSwapSpecific {
        LSSVMPair pair;
        uint256[] nftIds;
    }

    struct NFTsForAnyNFTsTrade {
        PairSwapSpecific[] nftToTokenTrades;
        PairSwapAny[] tokenToNFTTrades;
    }

    struct NFTsForSpecificNFTsTrade {
        PairSwapSpecific[] nftToTokenTrades;
        PairSwapSpecific[] tokenToNFTTrades;
    }

    // Used for arbitrage across several pools
    struct TokenToTokenTrade {
        PairSwapSpecific[] tokenToNFTTrades;
        PairSwapSpecific[] nftToTokenTrades;
    }

    modifier checkDeadline(uint256 deadline) {
        _checkDeadline(deadline);
        _;
    }

    LSSVMPairFactoryLike public immutable factory;

    constructor(LSSVMPairFactoryLike _factory) {
        factory = _factory;
    }

    /**
        ETH swaps
     */

    /**
        @notice Swaps ETH into NFTs using multiple pairs.
        @param swapList The list of pairs to trade with and the number of NFTs to buy from each.
        @param maxCost The maximum acceptable total ETH cost
        @param ethRecipient The address that will receive the unspent ETH input
        @param nftRecipient The address that will receive the NFT output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return remainingValue The unspent ETH amount
     */
    function swapETHForAnyNFTs(
        PairSwapAny[] calldata swapList,
        uint256 maxCost,
        address payable ethRecipient,
        address nftRecipient,
        uint256 deadline
    )
        external
        payable
        checkDeadline(deadline)
        returns (uint256 remainingValue)
    {
        return
            _swapETHForAnyNFTs(
                swapList,
                msg.value,
                maxCost,
                ethRecipient,
                nftRecipient
            );
    }

    /**
        @notice Swaps ETH into specific NFTs using multiple pairs.
        @param swapList The list of pairs to trade with and the IDs of the NFTs to buy from each.
        @param maxCost The maximum acceptable total ETH cost
        @param ethRecipient The address that will receive the unspent ETH input
        @param nftRecipient The address that will receive the NFT output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return remainingValue The unspent ETH amount
     */
    function swapETHForSpecificNFTs(
        PairSwapSpecific[] calldata swapList,
        uint256 maxCost,
        address payable ethRecipient,
        address nftRecipient,
        uint256 deadline
    )
        external
        payable
        checkDeadline(deadline)
        returns (uint256 remainingValue)
    {
        return
            _swapETHForSpecificNFTs(
                swapList,
                msg.value,
                maxCost,
                ethRecipient,
                nftRecipient
            );
    }

    /**
        @notice Swaps one set of NFTs into another set of specific NFTs using multiple pairs, using
        ETH as the intermediary.
        @param trade The struct containing all NFT-to-ETH swaps and ETH-to-NFT swaps.
        @param minOutput The minimum acceptable total excess ETH received
        @param ethRecipient The address that will receive the ETH output
        @param nftRecipient The address that will receive the NFT output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return outputAmount The total ETH received
     */
    function swapNFTsForAnyNFTsThroughETH(
        NFTsForAnyNFTsTrade calldata trade,
        uint256 minOutput,
        address payable ethRecipient,
        address nftRecipient,
        uint256 deadline
    ) external payable checkDeadline(deadline) returns (uint256 outputAmount) {
        // Swap NFTs for ETH
        // minOutput of swap set to 0 since we're doing an aggregate slippage check
        outputAmount = _swapNFTsForToken(
            trade.nftToTokenTrades,
            0,
            payable(address(this))
        );

        // Add extra value to buy NFTs
        outputAmount += msg.value;

        // Swap ETH for any NFTs
        // cost <= maxCost = outputAmount - minOutput, so outputAmount' = outputAmount - cost >= minOutput
        outputAmount = _swapETHForAnyNFTs(
            trade.tokenToNFTTrades,
            outputAmount,
            outputAmount - minOutput,
            ethRecipient,
            nftRecipient
        );
    }

    /**
        @notice Swaps one set of NFTs into another set of specific NFTs using multiple pairs, using
        ETH as the intermediary.
        @param trade The struct containing all NFT-to-ETH swaps and ETH-to-NFT swaps.
        @param minOutput The minimum acceptable total excess ETH received
        @param ethRecipient The address that will receive the ETH output
        @param nftRecipient The address that will receive the NFT output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return outputAmount The total ETH received
     */
    function swapNFTsForSpecificNFTsThroughETH(
        NFTsForSpecificNFTsTrade calldata trade,
        uint256 minOutput,
        address payable ethRecipient,
        address nftRecipient,
        uint256 deadline
    ) external payable checkDeadline(deadline) returns (uint256 outputAmount) {
        // Swap NFTs for ETH
        // minOutput of swap set to 0 since we're doing an aggregate slippage check
        outputAmount = _swapNFTsForToken(
            trade.nftToTokenTrades,
            0,
            payable(address(this))
        );

        // Add extra value to buy NFTs
        outputAmount += msg.value;

        // Swap ETH for specific NFTs
        // cost <= maxCost = outputAmount - minOutput, so outputAmount' = outputAmount - cost >= minOutput
        outputAmount = _swapETHForSpecificNFTs(
            trade.tokenToNFTTrades,
            outputAmount,
            outputAmount - minOutput,
            ethRecipient,
            nftRecipient
        );
    }

    /**
        @dev This function reverts if no profit can be gained
        @notice Swaps ETH to NFTs and then back to ETH again, with the goal of arbitraging between pools
        @param trade The struct containing all ETH-to-NFT swaps and NFT-to-ETH swaps.
        @param minProfit The minimum accpetable amount of ETH profit
        @param ethRecipient The address that will receive the ETH output
        @param nftRecipient The address that will receive the NFT output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return profitAmount The total ETH profit received
     */
    function swapETHForETH(
        TokenToTokenTrade calldata trade,
        uint256 minProfit,
        address payable ethRecipient,
        address nftRecipient,
        uint256 deadline
    ) external payable checkDeadline(deadline) returns (uint256 profitAmount) {
        // Assume we get everything we specified in trade.tokenToNFTTrades.nftIds
        // maxCost is set to infinity since we're doing slippage check later
        uint256 remainingValue = _swapETHForSpecificNFTs(
            trade.tokenToNFTTrades,
            msg.value,
            type(uint256).max,
            ethRecipient,
            nftRecipient
        );

        // Once we have all the NFTs, send them to the new pool for ETH
        // profitAmount = outputAmount + remainingValue - msg.value >= minProfit
        // thus outputAmount >= minOutput = msg.value - remainingValue + minProfit enforces slippage check
        uint256 outputAmount = _swapNFTsForToken(
            trade.nftToTokenTrades,
            msg.value - remainingValue + minProfit,
            ethRecipient
        );

        profitAmount = outputAmount - msg.value + remainingValue;
    }

    /**
        ERC20 swaps

        Note: All ERC20 swaps assume that a single ERC20 token is used for all the pairs involved.
        Swapping using multiple tokens in the same transaction is possible, but the slippage checks
        & the return values will be meaningless, and may lead to undefined behavior.

        Note: The sender should ideally grant infinite token approval to the router in order for NFT-to-NFT
        swaps to work smoothly.
     */

    /**
        @notice Swaps ERC20 tokens into NFTs using multiple pairs.
        @param swapList The list of pairs to trade with and the number of NFTs to buy from each.
        @param inputAmount The amount of ERC20 tokens to add to the ERC20-to-NFT swaps
        @param nftRecipient The address that will receive the NFT output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return remainingValue The unspent token amount
     */
    function swapERC20ForAnyNFTs(
        PairSwapAny[] calldata swapList,
        uint256 inputAmount,
        address nftRecipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 remainingValue) {
        return _swapERC20ForAnyNFTs(swapList, inputAmount, nftRecipient);
    }

    /**
        @notice Swaps ERC20 tokens into specific NFTs using multiple pairs.
        @param swapList The list of pairs to trade with and the IDs of the NFTs to buy from each.
        @param inputAmount The amount of ERC20 tokens to add to the ERC20-to-NFT swaps
        @param nftRecipient The address that will receive the NFT output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return remainingValue The unspent token amount
     */
    function swapERC20ForSpecificNFTs(
        PairSwapSpecific[] calldata swapList,
        uint256 inputAmount,
        address nftRecipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 remainingValue) {
        return _swapERC20ForSpecificNFTs(swapList, inputAmount, nftRecipient);
    }

    /**
        @notice Swaps NFTs into ETH/ERC20 using multiple pairs.
        @param swapList The list of pairs to trade with and the IDs of the NFTs to sell to each.
        @param minOutput The minimum acceptable total ETH received
        @param tokenRecipient The address that will receive the token output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return outputAmount The total ETH/ERC20 received
     */
    function swapNFTsForToken(
        PairSwapSpecific[] calldata swapList,
        uint256 minOutput,
        address tokenRecipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 outputAmount) {
        return _swapNFTsForToken(swapList, minOutput, payable(tokenRecipient));
    }

    /**
        @notice Swaps one set of NFTs into another set of specific NFTs using multiple pairs, using
        an ERC20 token as the intermediary.
        @param trade The struct containing all NFT-to-ERC20 swaps and ERC20-to-NFT swaps.
        @param inputAmount The amount of ERC20 tokens to add to the ERC20-to-NFT swaps
        @param minOutput The minimum acceptable total excess tokens received
        @param nftRecipient The address that will receive the NFT output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return outputAmount The total ERC20 tokens received
     */
    function swapNFTsForAnyNFTsThroughERC20(
        NFTsForAnyNFTsTrade calldata trade,
        uint256 inputAmount,
        uint256 minOutput,
        address nftRecipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 outputAmount) {
        // Swap NFTs for ERC20
        // minOutput of swap set to 0 since we're doing an aggregate slippage check
        // output tokens are sent to msg.sender
        outputAmount = _swapNFTsForToken(
            trade.nftToTokenTrades,
            0,
            payable(msg.sender)
        );

        // Add extra value to buy NFTs
        outputAmount += inputAmount;

        // Swap ERC20 for any NFTs
        // cost <= maxCost = outputAmount - minOutput, so outputAmount' = outputAmount - cost >= minOutput
        // input tokens are taken directly from msg.sender
        outputAmount = _swapERC20ForAnyNFTs(
            trade.tokenToNFTTrades,
            outputAmount - minOutput,
            nftRecipient
        );
    }

    /**
        @notice Swaps one set of NFTs into another set of specific NFTs using multiple pairs, using
        an ERC20 token as the intermediary.
        @param trade The struct containing all NFT-to-ERC20 swaps and ERC20-to-NFT swaps.
        @param inputAmount The amount of ERC20 tokens to add to the ERC20-to-NFT swaps
        @param minOutput The minimum acceptable total excess tokens received
        @param nftRecipient The address that will receive the NFT output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return outputAmount The total ERC20 tokens received
     */
    function swapNFTsForSpecificNFTsThroughERC20(
        NFTsForSpecificNFTsTrade calldata trade,
        uint256 inputAmount,
        uint256 minOutput,
        address nftRecipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 outputAmount) {
        // Swap NFTs for ERC20
        // minOutput of swap set to 0 since we're doing an aggregate slippage check
        // output tokens are sent to msg.sender
        outputAmount = _swapNFTsForToken(
            trade.nftToTokenTrades,
            0,
            payable(msg.sender)
        );

        // Add extra value to buy NFTs
        outputAmount += inputAmount;

        // Swap ERC20 for specific NFTs
        // cost <= maxCost = outputAmount - minOutput, so outputAmount' = outputAmount - cost >= minOutput
        // input tokens are taken directly from msg.sender
        outputAmount = _swapERC20ForSpecificNFTs(
            trade.tokenToNFTTrades,
            outputAmount - minOutput,
            nftRecipient
        );
    }

    /**
        @dev This function reverts if no profit can be gained.
        @notice Swaps ERC20 tokens to NFTs and then back to the token again, with the goal of arbitraging between pools
        @param trade The struct containing all ERC20-to-NFT swaps and NFT-to-ERC20 swaps.
        @param inputAmount The amount of ERC20 tokens to add to the ERC20-to-NFT swaps
        @param minProfit The minimum accpetable amount of ETH profit
        @param tokenRecipient The address that will receive the token output
        @param nftRecipient The address that will receive the NFT output
        @param deadline The Unix timestamp (in seconds) at/after which the swap will be revert
        @return profitAmount The total token profit received
     */
    function swapERC20ForERC20(
        TokenToTokenTrade calldata trade,
        uint256 inputAmount,
        uint256 minProfit,
        address tokenRecipient,
        address nftRecipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 profitAmount) {
        // Assume we get everything we specified in trade.tokenToNFTTrades.nftIds
        // maxCost is set to infinity since we're doing slippage check later
        uint256 remainingValue = _swapERC20ForSpecificNFTs(
            trade.tokenToNFTTrades,
            inputAmount,
            nftRecipient
        );

        // Once we have all the NFTs, send them to the new pool for tokens
        // profitAmount = outputAmount + remainingValue - inputAmount >= minProfit
        // thus outputAmount >= minOutput = inputAmount - remainingValue + minProfit enforces slippage check
        uint256 outputAmount = _swapNFTsForToken(
            trade.nftToTokenTrades,
            inputAmount - remainingValue + minProfit,
            payable(tokenRecipient)
        );

        profitAmount = outputAmount - inputAmount + remainingValue;
    }

    /**
        Robust swaps
        These are "robust" versions of the above swap functions which will never revert due to slippage
        Instead, if the price changes more than the user specifies, no swap is attempted
     */

    /**
        @dev We assume msg.value >= sum of values in maxCostPerPair
     */
    function robustSwapETHForAnyNFTs(
        PairSwapAny[] calldata swapList,
        uint256[] memory maxCostPerPairSwap,
        address payable ethRecipient,
        address nftRecipient,
        uint256 deadline
    )
        external
        payable
        checkDeadline(deadline)
        returns (uint256 remainingValue)
    {
        remainingValue = msg.value;

        // Try doing each swap
        uint256 pairCost;
        for (uint256 i = 0; i < swapList.length; i++) {
            // Calculate actual cost per swap
            (, , pairCost, ) = swapList[i].pair.getBuyNFTQuote(
                swapList[i].numItems
            );

            // If within our maxCost, proceed
            if (pairCost <= maxCostPerPairSwap[i]) {
                _verifyPairToken(swapList[i].pair, true);

                // We know how much ETH to send because we already did the math above
                // So we just send that much
                remainingValue -= swapList[i].pair.swapTokenForAnyNFTs{
                    value: pairCost
                }(swapList[i].numItems, nftRecipient, false, address(0));
            }
        }

        // Return remaining value to sender
        if (remainingValue > 0) {
            ethRecipient.sendValue(remainingValue);
        }
    }

    /**
        @dev We assume msg.value >= sum of values in maxCostPerPair
     */
    function robustSwapETHForSpecificNFTs(
        PairSwapSpecific[] calldata swapList,
        uint256[] memory maxCostPerPairSwapPair,
        address payable ethRecipient,
        address nftRecipient,
        uint256 deadline
    )
        external
        payable
        checkDeadline(deadline)
        returns (uint256 remainingValue)
    {
        remainingValue = msg.value;

        // Try doing each swap
        uint256 pairCost;
        for (uint256 i = 0; i < swapList.length; i++) {
            // Calculate actual cost per swap
            (, , pairCost, ) = swapList[i].pair.getBuyNFTQuote(
                swapList[i].nftIds.length
            );

            // If within our maxCost, proceed
            if (pairCost <= maxCostPerPairSwapPair[i]) {
                _verifyPairToken(swapList[i].pair, true);

                // We know how much ETH to send because we already did the math above
                // So we just send that much
                remainingValue -= swapList[i].pair.swapTokenForSpecificNFTs{
                    value: pairCost
                }(swapList[i].nftIds, nftRecipient, false, address(0));
            }
        }

        // Return remaining value to sender
        if (remainingValue > 0) {
            ethRecipient.sendValue(remainingValue);
        }
    }

    function robustSwapERC20ForAnyNFTs(
        PairSwapAny[] calldata swapList,
        uint256 inputAmount,
        uint256[] memory maxCostPerPairSwap,
        address nftRecipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 remainingValue) {
        remainingValue = inputAmount;

        // Try doing each swap
        uint256 pairCost;
        for (uint256 i = 0; i < swapList.length; i++) {
            // Calculate actual cost per swap
            (, , pairCost, ) = swapList[i].pair.getBuyNFTQuote(
                swapList[i].numItems
            );

            // If within our maxCost, proceed
            if (pairCost <= maxCostPerPairSwap[i]) {
                _verifyPairToken(swapList[i].pair, false);

                remainingValue -= swapList[i].pair.swapTokenForAnyNFTs(
                    swapList[i].numItems,
                    nftRecipient,
                    true,
                    msg.sender
                );
            }
        }
    }

    function robustSwapERC20ForSpecificNFTs(
        PairSwapSpecific[] calldata swapList,
        uint256 inputAmount,
        uint256[] memory maxCostPerPairSwapPair,
        address nftRecipient,
        uint256 deadline
    )
        external
        payable
        checkDeadline(deadline)
        returns (uint256 remainingValue)
    {
        remainingValue = inputAmount;

        // Try doing each swap
        uint256 pairCost;
        for (uint256 i = 0; i < swapList.length; i++) {
            // Calculate actual cost per swap
            (, , pairCost, ) = swapList[i].pair.getBuyNFTQuote(
                swapList[i].nftIds.length
            );

            // If within our maxCost, proceed
            if (pairCost <= maxCostPerPairSwapPair[i]) {
                _verifyPairToken(swapList[i].pair, false);

                remainingValue -= swapList[i].pair.swapTokenForSpecificNFTs(
                    swapList[i].nftIds,
                    nftRecipient,
                    true,
                    msg.sender
                );
            }
        }
    }

    function robustSwapNFTsForToken(
        PairSwapSpecific[] calldata swapList,
        uint256[] memory minOutputPerSwapPair,
        address payable tokenRecipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 outputAmount) {
        // Try doing each swap
        for (uint256 i = 0; i < swapList.length; i++) {
            uint256 pairOutput;
            (, , pairOutput, ) = swapList[i].pair.getSellNFTQuote(
                swapList[i].nftIds.length
            );

            // If at least equal to our minOutput, proceed
            if (pairOutput >= minOutputPerSwapPair[i]) {
                // Transfer NFTs directly from sender to pair
                IERC721 nft = swapList[i].pair.nft();

                // Signal transfer start to pair
                bytes memory signal = new bytes(1);
                signal[0] = NFT_TRANSFER_START;
                nft.safeTransferFrom(
                    msg.sender,
                    address(swapList[i].pair),
                    swapList[i].nftIds[0],
                    signal
                );

                // Transfer the remaining NFTs
                for (uint256 j = 1; j < swapList[i].nftIds.length; j++) {
                    nft.safeTransferFrom(
                        msg.sender,
                        address(swapList[i].pair),
                        swapList[i].nftIds[j]
                    );
                }

                // Do the swap and update outputAmount with how much ETH we got
                outputAmount += swapList[i].pair.routerSwapNFTsForToken(
                    tokenRecipient
                );
            }
        }
    }

    receive() external payable {}

    /**
        Restricted functions
     */

    /**
        @dev Allows an ERC20 pair contract to transfer ERC20 tokens directly from
        the sender, in order to minimize the number of token transfers. Only callable by an ERC20 pair.
        @param token The ERC20 token to transfer
        @param from The address to transfer tokens from
        @param amount The amount of tokens to transfer
        @param variant The pair variant of the pair contract
     */
    function pairTransferERC20From(
        IERC20 token,
        address from,
        uint256 amount,
        LSSVMPairFactoryLike.PairVariant variant
    ) external {
        // verify caller is a trusted pair contract
        require(factory.isPair(msg.sender, variant), "Not pair");

        // verify caller is an ERC20 pair
        require(
            variant == LSSVMPairFactoryLike.PairVariant.ENUMERABLE_ERC20 ||
                variant ==
                LSSVMPairFactoryLike.PairVariant.MISSING_ENUMERABLE_ERC20,
            "Not ERC20 pair"
        );

        // transfer tokens to pair
        token.safeTransferFrom(from, msg.sender, amount);
    }

    /**
        Internal functions
     */

    function _checkDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "Deadline passed");
    }

    /**
        @dev Verifies that a pair is an ETH pair or an ERC20 pair.
        If the pair is not of the expected type, the call reverts.
        @param pair The pair to verify
        @param shouldBeETH True if the pair should be an ETH pair, false otherwise
     */
    function _verifyPairToken(LSSVMPair pair, bool shouldBeETH) internal pure {
        LSSVMPairFactoryLike.PairVariant variant = pair.pairVariant();
        if (shouldBeETH) {
            require(
                variant ==
                    LSSVMPairFactoryLike.PairVariant.MISSING_ENUMERABLE_ETH ||
                    variant == LSSVMPairFactoryLike.PairVariant.ENUMERABLE_ETH,
                "Not ETH pair"
            );
        } else {
            require(
                variant ==
                    LSSVMPairFactoryLike.PairVariant.MISSING_ENUMERABLE_ERC20 ||
                    variant ==
                    LSSVMPairFactoryLike.PairVariant.ENUMERABLE_ERC20,
                "Not ERC20 pair"
            );
        }
    }

    function _swapETHForAnyNFTs(
        PairSwapAny[] calldata swapList,
        uint256 inputAmount,
        uint256 maxCost,
        address payable ethRecipient,
        address nftRecipient
    ) internal returns (uint256 remainingValue) {
        remainingValue = inputAmount;

        // Do swaps
        uint256 pairCost;
        for (uint256 i = 0; i < swapList.length; i++) {
            // Verify pair is an ETH pair
            _verifyPairToken(swapList[i].pair, true);

            (, , pairCost, ) = swapList[i].pair.getBuyNFTQuote(
                swapList[i].numItems
            );

            remainingValue -= swapList[i].pair.swapTokenForAnyNFTs{
                value: pairCost
            }(swapList[i].numItems, nftRecipient, false, address(0));
        }

        // Slippage check
        require(inputAmount - remainingValue <= maxCost, "Slippage");

        // Return remaining value to sender
        if (remainingValue > 0) {
            ethRecipient.sendValue(remainingValue);
        }
    }

    function _swapETHForSpecificNFTs(
        PairSwapSpecific[] calldata swapList,
        uint256 inputAmount,
        uint256 maxCost,
        address payable ethRecipient,
        address nftRecipient
    ) internal returns (uint256 remainingValue) {
        remainingValue = inputAmount;

        // Do swaps
        uint256 pairCost;
        for (uint256 i = 0; i < swapList.length; i++) {
            // Verify pair is an ETH pair
            _verifyPairToken(swapList[i].pair, true);

            (, , pairCost, ) = swapList[i].pair.getBuyNFTQuote(
                swapList[i].nftIds.length
            );

            remainingValue -= swapList[i].pair.swapTokenForSpecificNFTs{
                value: pairCost
            }(swapList[i].nftIds, nftRecipient, false, address(0));
        }

        // Slippage check
        require(inputAmount - remainingValue <= maxCost, "Slippage");

        // Return remaining value to sender
        if (remainingValue > 0) {
            ethRecipient.sendValue(remainingValue);
        }
    }

    function _swapERC20ForAnyNFTs(
        PairSwapAny[] calldata swapList,
        uint256 inputAmount,
        address nftRecipient
    ) internal returns (uint256 remainingValue) {
        remainingValue = inputAmount;

        // Do swaps
        for (uint256 i = 0; i < swapList.length; i++) {
            // Verify pair is an ERC20 pair
            _verifyPairToken(swapList[i].pair, false);

            // Tokens are transferred in by the pair calling router.pairTransferERC20From
            // Total tokens taken from sender cannot exceed inputAmount
            // because otherwise the deduction from remainingValue will fail
            remainingValue -= swapList[i].pair.swapTokenForAnyNFTs(
                swapList[i].numItems,
                nftRecipient,
                true,
                msg.sender
            );
        }
    }

    function _swapERC20ForSpecificNFTs(
        PairSwapSpecific[] calldata swapList,
        uint256 inputAmount,
        address nftRecipient
    ) internal returns (uint256 remainingValue) {
        remainingValue = inputAmount;

        // Do swaps
        for (uint256 i = 0; i < swapList.length; i++) {
            // Verify pair is an ERC20 pair
            _verifyPairToken(swapList[i].pair, false);

            // Tokens are transferred in by the pair calling router.pairTransferERC20From
            // Total tokens taken from sender cannot exceed inputAmount
            // because otherwise the deduction from remainingValue will fail
            remainingValue -= swapList[i].pair.swapTokenForSpecificNFTs(
                swapList[i].nftIds,
                nftRecipient,
                true,
                msg.sender
            );
        }
    }

    function _swapNFTsForToken(
        PairSwapSpecific[] calldata swapList,
        uint256 minOutput,
        address payable tokenRecipient
    ) internal returns (uint256 outputAmount) {
        bytes memory signal = new bytes(1);
        signal[0] = NFT_TRANSFER_START;

        // Do swaps
        for (uint256 i = 0; i < swapList.length; i++) {
            // Transfer NFTs directly from sender to pair
            IERC721 nft = swapList[i].pair.nft();

            // Signal transfer start to pair
            nft.safeTransferFrom(
                msg.sender,
                address(swapList[i].pair),
                swapList[i].nftIds[0],
                signal
            );

            // Transfer the remaining NFTs
            for (uint256 j = 1; j < swapList[i].nftIds.length; j++) {
                nft.safeTransferFrom(
                    msg.sender,
                    address(swapList[i].pair),
                    swapList[i].nftIds[j]
                );
            }

            // Do the swap for ETH and then update outputAmount
            // Note: minExpectedETHOutput is set to 0 since we're doing an aggregate slippage check
            outputAmount += swapList[i].pair.routerSwapNFTsForToken(
                tokenRecipient
            );
        }

        // Slippage check
        require(outputAmount >= minOutput, "outputAmount too low");
    }
}
