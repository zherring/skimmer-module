// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISmartVaultModuleManager } from "../../src/interfaces/ISmartVaultModuleManager.sol";

/// @notice Stand-in for a SmartVault. Implements the module surface the skimmer uses with the same semantics as the
///         deployed `ModuleManager`: only enabled modules may call `executeFromModule`, calls run in order, and the
///         first failing call reverts the whole batch with its revert data.
/// @dev Tests act as the account with `vm.prank(address(account))`, or through the open `exec` helper.
contract MockAccount {
    mapping(address => bool) public isModule;

    /// @notice Number of batches executed.
    uint256 public batchCount;

    ISmartVaultModuleManager.Call[] internal _lastBatch;

    error NotModule();

    function setModule(address module, bool enabled) external {
        isModule[module] = enabled;
    }

    function isModuleEnabled(address module) external view returns (bool) {
        return isModule[module];
    }

    function executeFromModule(ISmartVaultModuleManager.Call[] calldata calls) external {
        if (!isModule[msg.sender]) revert NotModule();

        delete _lastBatch;
        batchCount++;

        for (uint256 i; i < calls.length; ++i) {
            _lastBatch.push(calls[i]);
            (bool ok, bytes memory ret) = calls[i].target.call{ value: calls[i].value }(calls[i].data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    /// @notice The calls of the most recent batch, for shape assertions.
    function lastBatch() external view returns (ISmartVaultModuleManager.Call[] memory) {
        return _lastBatch;
    }

    /// @notice Open pass-through so tests can make the account do things (approve, deposit, withdraw).
    function exec(address target, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
