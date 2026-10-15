// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { YieldSkimmer } from "../../src/YieldSkimmer.sol";
import { NoopModule } from "../../src/NoopModule.sol";
import { ISmartVaultModuleManager } from "../../src/interfaces/ISmartVaultModuleManager.sol";

/// @dev Minimal view of `SmartVaultFactory` (0x8E6Af8Ed94E87B4402D0272C5D6b0D47F0483e7C, Sourcify exact match).
interface ISmartVaultFactory {
    struct Signer {
        bytes32 slot1;
        bytes32 slot2;
    }

    function IMPLEMENTATION() external view returns (address);

    function createAccount(
        address owner_,
        Signer[] calldata signers_,
        uint8 threshold_,
        uint256 salt_
    )
        external
        payable
        returns (address account);
}

/// @notice Runs the real module path on a Base fork: the real Splits Earn wrapper (Morpho VaultV2), a SmartVault
///         deployed through the real factory, and the skimmer enabled as a module on it.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test -vvv`. Skips (does not fail) when the fork cannot be created.
///
///      Transient-storage gotcha: `VaultV2.firstTotalAssets` is `transient`, and a forge test is one transaction. After
///      the first state-changing call on the wrapper, `accrueInterestView()` returns the stale stored total for the rest
///      of the test, so `vm.warp` no longer moves `convertToAssets`. Everything that mutates the wrapper (the account's
///      deposit) therefore happens in `setUp`, which is a separate call that starts with clean transient storage, and
///      each test performs its first `skim()` (views only) before touching the wrapper again.
contract YieldSkimmerForkTest is Test {
    address internal constant WRAPPER = 0x189A1a23F46321a196646314E6a078a404513C8F;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant FACTORY = 0x8E6Af8Ed94E87B4402D0272C5D6b0D47F0483e7C;
    address internal constant IMPLEMENTATION = 0x15ec0Fa66A0D96a64d67C58368641fBE9325F3FA;

    /// @dev EIP-1967 implementation slot.
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant DEPOSIT = 1_000_000e6;

    IERC4626 internal vault = IERC4626(WRAPPER);
    IERC20 internal usdc = IERC20(USDC);

    address internal owner = makeAddr("owner");
    address internal signer = makeAddr("signer");
    address internal stranger = makeAddr("stranger");
    address internal r1 = makeAddr("recipient1");
    address internal r2 = makeAddr("recipient2");

    address internal account;
    YieldSkimmer internal skimmer;

    function setUp() public {
        string memory url = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        try vm.createSelectFork(url) returns (uint256) { }
        catch {
            vm.skip(true, "cannot create a Base fork; set BASE_RPC_URL");
        }
        if (block.chainid != 8453) vm.skip(true, "RPC is not Base");

        // Sanity: these are the contracts the PRD says they are.
        assertEq(vault.asset(), USDC, "wrapper asset is Base USDC");
        assertEq(ISmartVaultFactory(FACTORY).IMPLEMENTATION(), IMPLEMENTATION, "factory implementation");

        // A fresh SmartVault through the real factory: EOA signer, threshold 1.
        ISmartVaultFactory.Signer[] memory signers = new ISmartVaultFactory.Signer[](1);
        signers[0] = ISmartVaultFactory.Signer({ slot1: bytes32(uint256(uint160(signer))), slot2: bytes32(0) });
        account = ISmartVaultFactory(FACTORY).createAccount(owner, signers, 1, uint256(keccak256("skimmer-fork-test")));

        // Fund it and put it in the wrapper, as the account itself.
        _fund(account, DEPOSIT);
        vm.startPrank(account);
        usdc.approve(WRAPPER, DEPOSIT);
        vault.deposit(DEPOSIT, account);
        vm.stopPrank();

        // The skimmer with permissive bounds; individual tests tighten them with `setCap`.
        skimmer = new YieldSkimmer(account, vault, usdc, 3000, 1_000_000e6);
        vm.prank(account);
        ISmartVaultModuleManager(account).enableModule(address(skimmer));
    }

    /* -------------------------------------------------------------------------- */
    /*                                   HELPERS                                  */
    /* -------------------------------------------------------------------------- */

    function _fund(address to, uint256 amount) internal {
        deal(USDC, to, amount);
        assertEq(usdc.balanceOf(to), amount, "deal on Base USDC did not work");
    }

    function _position() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(account));
    }

    function _addRecipients() internal {
        vm.startPrank(account);
        skimmer.addRecipient(r1, 4000, 1 days); // e.g. Song A Day
        skimmer.addRecipient(r2, 3000, 5 days); // e.g. a DCA recipient; the remaining 3000 compounds
        vm.stopPrank();
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || haystack.length < needle.length) return false;
        for (uint256 i; i <= haystack.length - needle.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /* -------------------------------------------------------------------------- */
    /*                           DEPLOYED CONTRACT SURFACE                        */
    /* -------------------------------------------------------------------------- */

    function test_fork_deployedImplementationExposesTheExpectedModuleSurface() public {
        // The selector our interface compiles to is the one the PRD and the deployed source use.
        assertEq(ISmartVaultModuleManager.executeFromModule.selector, bytes4(0xde77d70e));
        assertEq(ISmartVaultModuleManager.isModuleEnabled.selector, bytes4(0x2d9ad53d));
        assertEq(ISmartVaultModuleManager.enableModule.selector, bytes4(0x610b5925));
        assertEq(ISmartVaultModuleManager.disableModule.selector, bytes4(0xa95f5246));

        // The deployed implementation's dispatcher contains those selectors (PUSH4 <selector>)...
        bytes memory code = IMPLEMENTATION.code;
        assertTrue(_contains(code, abi.encodePacked(bytes1(0x63), bytes4(0xde77d70e))), "executeFromModule(Call[])");
        assertTrue(_contains(code, abi.encodePacked(bytes1(0x63), bytes4(0x610b5925))), "enableModule");
        assertTrue(_contains(code, abi.encodePacked(bytes1(0x63), bytes4(0xa95f5246))), "disableModule");
        assertTrue(_contains(code, abi.encodePacked(bytes1(0x63), bytes4(0x2d9ad53d))), "isModuleEnabled");

        // ...and calling it as a non-module reaches `onlyModule`, i.e. the function really is there.
        ISmartVaultModuleManager.Call[] memory none = new ISmartVaultModuleManager.Call[](0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OnlyModule()"))));
        ISmartVaultModuleManager(account).executeFromModule(none);

        // The account is an ERC-1967 proxy of that implementation.
        assertEq(address(uint160(uint256(vm.load(account, ERC1967_IMPLEMENTATION_SLOT)))), IMPLEMENTATION);
    }

    function test_fork_enableModuleIsOnlySelf() public {
        assertTrue(ISmartVaultModuleManager(account).isModuleEnabled(address(skimmer)));

        address other = makeAddr("other-module");
        vm.prank(stranger);
        vm.expectRevert();
        ISmartVaultModuleManager(account).enableModule(other);

        vm.prank(owner); // the owner reaches it through `execute`, not directly
        vm.expectRevert();
        ISmartVaultModuleManager(account).enableModule(other);
    }

    /// @dev Rollout step 1 on a real SmartVault: an empty module can be enabled and disabled by self-call.
    function test_fork_noopModuleCanBeEnabledAndDisabled() public {
        NoopModule noop = new NoopModule();

        vm.prank(account);
        ISmartVaultModuleManager(account).enableModule(address(noop));
        assertTrue(ISmartVaultModuleManager(account).isModuleEnabled(address(noop)));

        vm.prank(account);
        ISmartVaultModuleManager(account).disableModule(address(noop));
        assertFalse(ISmartVaultModuleManager(account).isModuleEnabled(address(noop)));
    }

    /* -------------------------------------------------------------------------- */
    /*                                 WRAPPER FACTS                              */
    /* -------------------------------------------------------------------------- */

    function test_fork_accountCanWithdrawFromItselfWithoutAllowance() public {
        uint256 sharesBefore = vault.balanceOf(account);
        assertGt(sharesBefore, 0);
        assertEq(IERC20(WRAPPER).allowance(account, account), 0);

        // `maxWithdraw` is hard-coded to 0 on Morpho V2; the module never consults it.
        assertEq(vault.maxWithdraw(account), 0, "maxWithdraw is pure 0 on VaultV2");

        vm.prank(account);
        vault.withdraw(1000e6, account, account);
        assertEq(usdc.balanceOf(account), 1000e6);
        assertLt(vault.balanceOf(account), sharesBefore);

        // Nobody else can pull the account's shares without an allowance.
        vm.prank(stranger);
        vm.expectRevert();
        vault.withdraw(1000e6, stranger, account);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  SKIM FLOW                                 */
    /* -------------------------------------------------------------------------- */

    function test_fork_skim_movesRealYieldIntoTheModule() public {
        _addRecipients();

        // First skim: views only on the wrapper. Records the watermark, moves nothing.
        skimmer.skim();
        uint256 principal0 = skimmer.principal();
        assertEq(principal0, _position());
        assertGt(principal0, DEPOSIT - 10, "position is the deposit, give or take rounding");
        assertEq(usdc.balanceOf(address(skimmer)), 0);

        // 30 days of real Morpho share-price growth (the wrapper accrues lazily from the adapters' real assets).
        vm.warp(block.timestamp + 30 days);
        assertGt(_position(), principal0, "share price did not move after 30 days");

        (uint256 previewYield, uint256 previewTake) = skimmer.previewSkim();
        assertGt(previewYield, 0);
        assertEq(previewTake, previewYield * 7000 / 10_000);
        console2.log("30d yield on 1,000,000 USDC (USDC wei):", previewYield);

        uint256 positionBefore = _position();
        skimmer.skim();

        // USDC landed in the module, exactly what was previewed, and nothing is stuck on the account.
        assertEq(usdc.balanceOf(address(skimmer)), previewTake, "take landed in the module");
        assertEq(usdc.balanceOf(account), 0, "nothing left idle on the account");
        assertEq(skimmer.accrued(r1), previewYield * 4000 / 10_000);
        assertEq(skimmer.accrued(r2), previewYield * 3000 / 10_000);

        // The position fell by the take (plus at most a wei or two of share rounding) and still covers the watermark.
        uint256 positionAfter = _position();
        assertApproxEqAbs(positionBefore - positionAfter, previewTake, 2);
        assertGe(positionAfter, skimmer.principal(), "position >= principal");
        // Retained 30% of the yield is now principal.
        assertApproxEqAbs(skimmer.principal(), principal0 + (previewYield - previewTake), 2);

        // Recipients pull what they were credited; only they receive.
        skimmer.pull(r1);
        assertEq(usdc.balanceOf(r1), previewYield * 4000 / 10_000);
        skimmer.pull(r2);
        assertEq(usdc.balanceOf(r2), previewYield * 3000 / 10_000);
        assertLe(usdc.balanceOf(address(skimmer)), 1, "only rounding dust is left");
    }

    /// @dev PRD parameters: 30% APR ceiling and a $50 per-skim cap. After a month the real yield is well above $50.
    function test_fork_skim_absoluteMaxPerSkimBindsOnRealYield() public {
        _addRecipients();
        vm.prank(account);
        skimmer.setCap(3000, 50e6);

        skimmer.skim();
        vm.warp(block.timestamp + 30 days);
        (uint256 previewYield,) = skimmer.previewSkim();
        assertEq(previewYield, 50e6, "capped at $50");

        skimmer.skim();
        assertEq(usdc.balanceOf(address(skimmer)), 35e6, "70% of $50");
        assertGe(_position(), skimmer.principal());
    }

    /// @dev An unannounced deposit is absorbed rather than skimmed; the cap bounds what a false positive can cost.
    function test_fork_skim_unannouncedDepositIsAbsorbed() public {
        _addRecipients();
        vm.prank(account);
        skimmer.setCap(3000, 50e6);

        skimmer.skim();
        uint256 principal0 = skimmer.principal();

        vm.warp(block.timestamp + 1 days);
        _fund(account, 100_000e6);
        vm.startPrank(account);
        usdc.approve(WRAPPER, 100_000e6);
        vault.deposit(100_000e6, account);
        vm.stopPrank();

        uint256 positionBefore = _position();
        assertGt(positionBefore, principal0 + 99_000e6);

        skimmer.skim();

        // At most $50 moved, even though $100k appeared above the watermark.
        assertEq(usdc.balanceOf(address(skimmer)), 35e6);
        // Everything above one ceiling's worth of the deposit became principal.
        uint256 ceiling = principal0 * 3000 * 1 days / (365 days * 10_000);
        assertGe(skimmer.principal(), positionBefore - ceiling - 2);
        assertGe(_position(), skimmer.principal());
    }

    function test_fork_skim_withdrawalByTheOwnerRatchetsPrincipalDown() public {
        skimmer.skim();
        uint256 principal0 = skimmer.principal();

        vm.warp(block.timestamp + 1 days);
        vm.prank(account);
        vault.withdraw(250_000e6, account, account);

        skimmer.skim();
        assertLt(skimmer.principal(), principal0 - 249_000e6);
        assertEq(skimmer.principal(), _position());
        assertEq(usdc.balanceOf(address(skimmer)), 0);
    }

    function test_fork_skim_revertsOnceTheModuleIsDisabled() public {
        _addRecipients();
        skimmer.skim();
        vm.warp(block.timestamp + 30 days);

        vm.prank(account);
        ISmartVaultModuleManager(account).disableModule(address(skimmer));

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OnlyModule()"))));
        skimmer.skim();
    }
}
