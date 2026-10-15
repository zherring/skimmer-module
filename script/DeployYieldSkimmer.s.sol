// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { YieldSkimmer } from "../src/YieldSkimmer.sol";
import { ISmartVaultModuleManager } from "../src/interfaces/ISmartVaultModuleManager.sol";
import { ModuleOps } from "./ModuleOps.sol";

/// @notice Rollout step 2: sanity-check the endowment subaccount, deploy `YieldSkimmer` through the deterministic
///         CREATE2 deployer (so the address is predictable), and print how to enable it.
/// @dev Env:
///        ACCOUNT                 required. The endowment subaccount.
///        VAULT                   default splitsUSDC `0x189A…3C8F`.
///        ASSET                   default Base USDC.
///        CAP_BPS                 default 3000 (30% APR ceiling).
///        ABSOLUTE_MAX_PER_SKIM   default 50e6 (50 USDC; asset units).
///        SALT                    default `keccak256("skimmer-module/YieldSkimmer/v1")`.
///      Dry run (prints the predicted address and calldata, sends nothing):
///        ACCOUNT=0x… forge script script/DeployYieldSkimmer.s.sol --rpc-url $BASE_RPC_URL
///      Live: add `--broadcast --account <keystore-name>` (or `--private-key`).
contract DeployYieldSkimmer is ModuleOps {
    struct Config {
        address account;
        address vault;
        address asset;
        uint16 capBps;
        uint256 absoluteMaxPerSkim;
        bytes32 salt;
    }

    function run() external returns (YieldSkimmer skimmer) {
        Config memory c = _config();
        _preflight(c);

        bytes memory constructorArgs = abi.encode(c.account, c.vault, c.asset, c.capBps, c.absoluteMaxPerSkim);
        address predicted = vm.computeCreate2Address(
            c.salt, keccak256(abi.encodePacked(type(YieldSkimmer).creationCode, constructorArgs)), CREATE2_FACTORY
        );
        console2.log("Predicted YieldSkimmer:", predicted);

        if (predicted.code.length != 0) {
            console2.log("Already deployed at the predicted address; skipping the deploy.");
            skimmer = YieldSkimmer(predicted);
        } else {
            vm.startBroadcast();
            skimmer = new YieldSkimmer{ salt: c.salt }(
                c.account, IERC4626(c.vault), IERC20(c.asset), c.capBps, c.absoluteMaxPerSkim
            );
            vm.stopBroadcast();
            require(address(skimmer) == predicted, "deployed address differs from the CREATE2 prediction");
        }

        console2.log("YieldSkimmer:", address(skimmer));
        console2.log("Verify (do not run blindly): forge verify-contract --verifier sourcify --chain base \\");
        console2.log(string.concat("  --constructor-args ", vm.toString(constructorArgs), " \\"));
        console2.log(string.concat("  ", vm.toString(address(skimmer)), " src/YieldSkimmer.sol:YieldSkimmer"));

        if (ISmartVaultModuleManager(c.account).isModuleEnabled(address(skimmer))) {
            console2.log("Already enabled on the account.");
        }
        _printModuleInstructions(c.account, address(skimmer), "YieldSkimmer");
    }

    function _config() internal view returns (Config memory c) {
        c.account = vm.envAddress("ACCOUNT");
        c.vault = vm.envOr("VAULT", SPLITS_USDC_VAULT);
        c.asset = vm.envOr("ASSET", USDC);
        c.absoluteMaxPerSkim = vm.envOr("ABSOLUTE_MAX_PER_SKIM", uint256(50e6));
        c.salt = vm.envOr("SALT", keccak256("skimmer-module/YieldSkimmer/v1"));

        uint256 capBps = vm.envOr("CAP_BPS", uint256(3000));
        require(capBps != 0 && capBps <= type(uint16).max, "CAP_BPS must be in 1..65535");
        // forge-lint: disable-next-line(unsafe-typecast)
        c.capBps = uint16(capBps);
    }

    /// @dev Reverts on a wrong setup, warns on an unusual one. `vault` is immutable in the module, so the shares must
    ///      already be in it (PRD, "Parameters for the first deployment").
    function _preflight(Config memory c) internal view {
        _checkAccount(c.account);

        require(c.vault.code.length != 0, "VAULT has no code on this chain");
        address vaultAsset = IERC4626(c.vault).asset();
        require(
            vaultAsset == c.asset,
            string.concat("VAULT.asset() is ", vm.toString(vaultAsset), " but ASSET is ", vm.toString(c.asset))
        );

        uint256 vaultShares = IERC20(c.vault).balanceOf(c.account);
        uint256 legacyShares = IERC20(LEGACY_AAVE_VAULT).balanceOf(c.account);
        if (vaultShares == 0) {
            if (legacyShares != 0) revert("ACCOUNT holds legacy Aave vault shares and none in VAULT: migrate first");
            revert("ACCOUNT holds no VAULT shares: deposit into the Earn vault first");
        }
        if (legacyShares != 0) {
            _warn(
                string.concat(
                    "ACCOUNT still holds ",
                    vm.toString(legacyShares),
                    " shares of the legacy Aave vault; they are not skimmed and not counted as principal"
                )
            );
        }

        if (!ISmartVaultModuleManager(c.account).isModuleEnabled(AUTO_EARN_MODULE_V2)) {
            _warn("AutoEarnModuleV2 is not enabled on ACCOUNT: idle USDC will not be swept into VAULT");
        }

        console2.log("account:               ", c.account);
        console2.log("vault:                 ", c.vault);
        console2.log("asset:                 ", c.asset);
        console2.log("vault shares (account):", vaultShares);
        console2.log("position (asset units):", IERC4626(c.vault).convertToAssets(vaultShares));
        console2.log("capBps:                ", uint256(c.capBps));
        console2.log("absoluteMaxPerSkim:    ", c.absoluteMaxPerSkim);
    }
}
