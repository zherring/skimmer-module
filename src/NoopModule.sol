// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title NoopModule
/// @notice An intentionally empty SmartVault module for rollout step 1: enable it on an account with
///         `enableModule(address)`, confirm `isModuleEnabled`, then `disableModule(address)`. It proves the Splits
///         platform lets a custom self-call through without giving the module any ability to do anything.
/// @dev There is no function that could ever call `executeFromModule` on the account, no state, and no admin.
contract NoopModule {
    /// @notice Marker so the deployed bytecode is not completely empty and is easy to recognise.
    uint256 public constant VERSION = 1;
}
