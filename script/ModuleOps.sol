// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { ISmartVaultModuleManager } from "../src/interfaces/ISmartVaultModuleManager.sol";

/// @notice Shared pieces of the deploy scripts: the Base addresses from the PRD ("Verified onchain"), the account
///         sanity checks, and the "what do I do with this module now" printout (calldata, Splits CLI, verification).
abstract contract ModuleOps is Script {
    /// @dev Splits Earn USDC wrapper (`splitsUSDC`, Morpho VaultV2).
    address internal constant SPLITS_USDC_VAULT = 0x189A1a23F46321a196646314E6a078a404513C8F;
    /// @dev Native USDC on Base.
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev Legacy Aave `stataBasUSDC` vault; accounts enrolled before the wrapper may still hold shares here.
    address internal constant LEGACY_AAVE_VAULT = 0x4EA71A20e655794051D1eE8b6e4A3269B13ccaCc;
    /// @dev `AutoEarnModuleV2`: sweeps an account's idle USDC into the wrapper.
    address internal constant AUTO_EARN_MODULE_V2 = 0x4A5aCfc49597D1D326221cd159d42817918B9F5f;
    /// @dev SmartVault implementation every factory account proxies to (accounts can be upgraded individually).
    address internal constant KNOWN_IMPLEMENTATION = 0x15ec0Fa66A0D96a64d67C58368641fBE9325F3FA;
    /// @dev EIP-1967 implementation slot.
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant BASE_CHAIN_ID = 8453;

    /// @dev The account must be a contract, should proxy the known implementation, and must speak the module manager
    ///      interface. Reverts on the first, warns on the second, reverts on the third.
    function _checkAccount(address account) internal view {
        if (block.chainid != BASE_CHAIN_ID) {
            _warn(string.concat("chain id is ", vm.toString(block.chainid), ", not Base (8453)"));
        }

        require(account.code.length != 0, "ACCOUNT has no code on this chain: wrong RPC or account not deployed");

        address implementation = address(uint160(uint256(vm.load(account, ERC1967_IMPLEMENTATION_SLOT))));
        if (implementation != KNOWN_IMPLEMENTATION) {
            _warn(
                string.concat(
                    "ACCOUNT implementation is ",
                    vm.toString(implementation),
                    ", not the known ",
                    vm.toString(KNOWN_IMPLEMENTATION),
                    " (accounts can be upgraded individually); check its ModuleManager before going on"
                )
            );
        }

        // Low-level on purpose: a try/catch cannot catch the caller-side decode failure of an empty return.
        (bool ok, bytes memory ret) =
            account.staticcall(abi.encodeCall(ISmartVaultModuleManager.isModuleEnabled, (address(0))));
        require(ok && ret.length == 32, "ACCOUNT does not answer isModuleEnabled(address): is it a Splits SmartVault?");
    }

    /// @dev Prints everything needed to turn a deployed `module` on and off for `account`, and to check it.
    function _printModuleInstructions(address account, address module, string memory name) internal view {
        string memory acct = vm.toString(account);
        string memory mod = vm.toString(module);

        bytes memory enableData = abi.encodeCall(ISmartVaultModuleManager.enableModule, (module));
        bytes memory disableData = abi.encodeCall(ISmartVaultModuleManager.disableModule, (module));

        console2.log("");
        console2.log("== Enable (a self-call: target = the account itself, value 0) ==");
        console2.log(string.concat("enableModule calldata: ", vm.toString(enableData)));
        console2.log(
            "NOTE: splits-cli 0.3.0 rejects a JSON --calls on argv (checked 2026-10-15); if yours does, use the MCP form."
        );
        _printSplitsCall(acct, enableData, string.concat("Enable ", name, " ", mod));

        console2.log("");
        console2.log("== Verify ==");
        console2.log(
            string.concat(
                "cast call ", acct, ' "isModuleEnabled(address)(bool)" ', mod, ' --rpc-url "$BASE_RPC_URL"   # -> true'
            )
        );

        console2.log("");
        console2.log("== Disable (same shape; for the skimmer, call drainTo(account) first) ==");
        console2.log(string.concat("disableModule calldata: ", vm.toString(disableData)));
        _printSplitsCall(acct, disableData, string.concat("Disable ", name, " ", mod));
    }

    /// @dev The `--calls` flag is an array of `{to, data, value}` objects (`splits transactions create custom --help`).
    ///      splits-cli 0.3.0 parses argv with incur 0.3.13, which hands array items to zod as strings, so a JSON
    ///      `--calls` value fails validation ("expected object, received string"). The MCP tool
    ///      `transactions_create_custom` takes the same payload as JSON, so both forms are printed.
    function _printSplitsCall(string memory acct, bytes memory data, string memory memo) internal view {
        string memory calls = string.concat('[{"to":"', acct, '","data":"', vm.toString(data), '","value":"0"}]');
        string memory chainId = vm.toString(block.chainid);

        console2.log("Splits CLI (as documented):");
        console2.log(
            string.concat("  splits transactions create custom --account ", acct, " --chain-id ", chainId, " \\")
        );
        console2.log(string.concat("    --calls '", calls, "' \\"));
        console2.log(string.concat('    --memo "', memo, '"'));
        console2.log("MCP tool transactions_create_custom, arguments:");
        console2.log(
            string.concat('  {"account":"', acct, '","chainId":', chainId, ',"calls":', calls, ',"memo":"', memo, '"}')
        );
    }

    function _warn(string memory message) internal pure {
        console2.log(string.concat("WARNING: ", message));
    }
}
