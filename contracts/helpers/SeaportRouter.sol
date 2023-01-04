// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {
    AdvancedOrderParams,
    FulfillAvailableAdvancedOrdersParams
} from "./SeaportRouterStructs.sol";

import { SeaportRouterErrors } from "../interfaces/SeaportRouterErrors.sol";

import { Execution } from "../lib/ConsiderationStructs.sol";

import { SeaportInterface } from "../interfaces/SeaportInterface.sol";

import { ReentrancyGuard } from "../lib/ReentrancyGuard.sol";

/**
 * @title  SeaportRouter
 * @author ryanio
 * @notice A utility contract for interacting with multiple Seaport versions.
 */
contract SeaportRouter is SeaportRouterErrors, ReentrancyGuard {
    /**
     *  @dev The allowed Seaport contracts usable through this router.
     */
    address private immutable _SEAPORT_V1_1;
    address private immutable _SEAPORT_V1_2;

    /**
     * @dev Deploy contract with the supported Seaport contracts.
     */
    constructor(address SEAPORT_V1_1, address SEAPORT_V1_2) {
        _SEAPORT_V1_1 = SEAPORT_V1_1;
        _SEAPORT_V1_2 = SEAPORT_V1_2;
    }

    /**
     * @notice Returns the Seaport contracts allowed to be used through this
     *         router.
     */
    function getAllowedSeaportContracts()
        public
        view
        returns (address[] memory seaportContracts)
    {
        seaportContracts = new address[](2);
        seaportContracts[0] = _SEAPORT_V1_1;
        seaportContracts[1] = _SEAPORT_V1_2;
    }

    /**
     * @notice Fulfill available advanced orders through multiple Seaport
     *         versions.
     *         See {SeaportInterface-fulfillAvailableAdvancedOrders}
     */
    function fulfillAvailableAdvancedOrders(
        FulfillAvailableAdvancedOrdersParams calldata params
    )
        external
        payable
        returns (
            bool[][] memory availableOrders,
            Execution[][] memory executions
        )
    {
        // Ensure this function cannot be triggered during a reentrant call.
        _assertNonReentrant();

        // Put the number of Seaport contracts on the stack.
        uint256 seaportContractsLength = params.seaportContracts.length;

        // Set the availableOrders and executions arrays to the correct length.
        availableOrders = new bool[][](seaportContractsLength);
        executions = new Execution[][](seaportContractsLength);

        // Track the number of order fulfillments left.
        uint256 fulfillmentsLeft = params.maximumFulfilled;

        // Iterate through the provided Seaport contracts.
        for (uint256 i = 0; i < seaportContractsLength; ) {
            address seaport = params.seaportContracts[i];
            // Ensure the provided Seaport contract is allowed.
            if (seaport != _SEAPORT_V1_1 && seaport != _SEAPORT_V1_2) {
                revert SeaportNotAllowed(seaport);
            }

            // Put the order params on the stack.
            AdvancedOrderParams calldata orderParams = params
                .advancedOrderParams[i];

            // Execute the orders, collecting the availableOrders and executions.
            // This is wrapped in a try/catch in case a single order is executed that
            // is no longer available, leading to a revert with NoSpecifiedOrdersAvailable().
            try
                SeaportInterface(seaport).fulfillAvailableAdvancedOrders{
                    value: orderParams.value
                }(
                    orderParams.advancedOrders,
                    orderParams.criteriaResolvers,
                    orderParams.offerFulfillments,
                    orderParams.considerationFulfillments,
                    params.fulfillerConduitKey,
                    params.recipient,
                    fulfillmentsLeft
                )
            returns (
                bool[] memory newAvailableOrders,
                Execution[] memory newExecutions
            ) {
                availableOrders[i] = newAvailableOrders;
                executions[i] = newExecutions;
                // Subtract the number of orders fulfilled.
                uint256 newAvailableOrdersLength = newAvailableOrders.length;
                for (uint256 j = 0; j < newAvailableOrdersLength; ) {
                    if (availableOrders[i][j]) {
                        unchecked {
                            --fulfillmentsLeft;
                            ++j;
                        }
                    }
                }

                // Break if the maximum number of executions has been reached.
                if (fulfillmentsLeft == 0) {
                    break;
                }
            } catch {}

            unchecked {
                ++i;
            }
        }

        // Return excess ether that may not have been used.
        if (address(this).balance > 0) {
            _returnExcessEther();
        }
    }

    /**
     * @dev Fallback function to receive excess ether, in case total amount of
     *      ether sent is more than the amount required to fulfill the order.
     */
    receive() external payable {
        // Return excess ether in the same transaction.
        _returnExcessEther();
    }

    /**
     * @dev Fallback function to receive excess ether, in case total amount of
     *      ether sent is more than the amount required to fulfill the order.
     */
    fallback() external payable {
        // Return excess ether in the same transaction.
        _returnExcessEther();
    }

    /**
     * @dev Fallback function to return excess ether, in case total amount of
     *      ether sent is more than the amount required to fulfill the order.
     */
    function _returnExcessEther() private {
        // Ensure this function cannot be triggered during a reentrant call.
        _setReentrancyGuard();

        // Send received funds back to msg.sender.
        (bool success, bytes memory data) = payable(msg.sender).call{
            value: address(this).balance
        }("");

        // Revert with an error if the ether transfer failed.
        if (!success) {
            revert EtherReturnTransferFailed(
                msg.sender,
                address(this).balance,
                data
            );
        }

        // Clear the reentrancy guard.
        _clearReentrancyGuard();
    }
}
