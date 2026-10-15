// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { console2 } from "forge-std/Script.sol";

import { NoopModule } from "../src/NoopModule.sol";
import { ModuleOps } from "./ModuleOps.sol";

/// @notice Rollout step 1: deploy the empty `NoopModule` through the deterministic CREATE2 deployer, then print how to
///         enable and disable it on a subaccount.
/// @dev Env: `ACCOUNT` (optional; the subaccount to print the enable/disable instructions for) and `SALT` (optional,
///      default `keccak256("skimmer-module/NoopModule/v1")`).
///      Dry run: `forge script script/DeployNoopModule.s.sol --rpc-url $BASE_RPC_URL`.
///      Live:    add `--broadcast --account <keystore-name>` (or `--private-key`).
contract DeployNoopModule is ModuleOps {
    function run() external returns (NoopModule noop) {
        address account = vm.envOr("ACCOUNT", address(0));
        bytes32 salt = vm.envOr("SALT", keccak256("skimmer-module/NoopModule/v1"));

        if (account != address(0)) _checkAccount(account);

        address predicted = vm.computeCreate2Address(salt, keccak256(type(NoopModule).creationCode), CREATE2_FACTORY);
        console2.log("Predicted NoopModule:", predicted);

        if (predicted.code.length != 0) {
            console2.log("Already deployed at the predicted address; skipping the deploy.");
            noop = NoopModule(predicted);
        } else {
            vm.startBroadcast();
            noop = new NoopModule{ salt: salt }();
            vm.stopBroadcast();
            require(address(noop) == predicted, "deployed address differs from the CREATE2 prediction");
        }

        console2.log("NoopModule:", address(noop));
        console2.log("Verify (do not run blindly): forge verify-contract --verifier sourcify --chain base \\");
        console2.log(string.concat("  ", vm.toString(address(noop)), " src/NoopModule.sol:NoopModule"));

        if (account == address(0)) {
            console2.log("Set ACCOUNT=<subaccount> to also print the enable/disable calldata and Splits CLI calls.");
        } else {
            _printModuleInstructions(account, address(noop), "NoopModule");
        }
    }
}
