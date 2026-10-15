// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

/// @title ISmartVaultModuleManager
/// @notice The slice of the Splits SmartVault `ModuleManager` that a module needs.
/// @dev Copied from the deployed implementation `0x15ec0Fa66A0D96a64d67C58368641fBE9325F3FA` on Base
///      (`src/utils/ModuleManager.sol` and `src/utils/Caller.sol`, Sourcify exact match), which is GPL-3.0-or-later.
///      Only the functions this repo uses are declared. In particular the single-`Call` overload of
///      `executeFromModule` (`0x57c94f2e`) is left out on purpose.
///
///      The deployed `executeFromModule(Call[])` has NO return value. Declaring one here would make the caller revert
///      when it tries to ABI-decode empty returndata, so none is declared.
interface ISmartVaultModuleManager {
    /// @notice A call to execute from the account. Mirrors `Caller.Call`.
    struct Call {
        /// @dev The address to call.
        address target;
        /// @dev The value to send when making the call.
        uint256 value;
        /// @dev The data of the call.
        bytes data;
    }

    /// @notice Executes `calls_` from the account. Callable only by an enabled module; reverts with the first failing
    ///         call's revert data.
    /// @dev selector 0xde77d70e
    function executeFromModule(Call[] calldata calls_) external;

    /// @notice Whether `module_` is enabled on the account.
    /// @dev selector 0x2d9ad53d
    function isModuleEnabled(address module_) external view returns (bool);

    /// @notice Enables `module_`. `onlySelf`: the account must call itself.
    /// @dev selector 0x610b5925
    function enableModule(address module_) external;

    /// @notice Disables `module_`. `onlySelf`: the account must call itself.
    /// @dev selector 0xa95f5246
    function disableModule(address module_) external;
}
