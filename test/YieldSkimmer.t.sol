// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { YieldSkimmer } from "../src/YieldSkimmer.sol";
import { NoopModule } from "../src/NoopModule.sol";
import { ISmartVaultModuleManager } from "../src/interfaces/ISmartVaultModuleManager.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockVault } from "./mocks/MockVault.sol";
import { MockAccount } from "./mocks/MockAccount.sol";

contract YieldSkimmerTest is Test {
    uint256 internal constant DEPOSIT = 100_000e6;
    uint16 internal constant CAP = 3000;
    uint256 internal constant ABS_MAX = 1_000_000e6; // effectively unbounded unless a test lowers it

    MockERC20 internal usdc;
    MockVault internal vault;
    MockAccount internal account;
    YieldSkimmer internal skimmer;

    address internal r1 = makeAddr("recipient1");
    address internal r2 = makeAddr("recipient2");
    address internal r3 = makeAddr("recipient3");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_800_000_000);

        usdc = new MockERC20();
        vault = new MockVault(usdc);
        account = new MockAccount();
        skimmer = new YieldSkimmer(address(account), IERC4626(address(vault)), IERC20(address(usdc)), CAP, ABS_MAX);
        account.setModule(address(skimmer), true);

        _deposit(DEPOSIT);
    }

    /* -------------------------------------------------------------------------- */
    /*                                   HELPERS                                  */
    /* -------------------------------------------------------------------------- */

    function _deposit(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, address(account));
    }

    /// @dev Sets the share price so the account's position is exactly `target`. Exact because the account's share
    ///      count is far below 1e30 (see the rounding note in the repo README / test comments).
    function _setPosition(uint256 target) internal {
        uint256 shares = vault.balanceOf(address(account));
        vault.setPricePerShare(Math.mulDiv(target, 1e30, shares, Math.Rounding.Ceil));
        assertEq(skimmer.position(), target, "setPosition not exact");
    }

    function _addYield(uint256 amount) internal {
        _setPosition(skimmer.position() + amount);
    }

    function _add(address r, uint16 share, uint32 interval) internal {
        vm.prank(address(account));
        skimmer.addRecipient(r, share, interval);
    }

    function _firstSkim() internal {
        skimmer.skim();
    }

    /// @dev Independent restatement of the PRD ceiling with plain arithmetic.
    function _ceiling(uint256 p, uint256 dt) internal pure returns (uint256) {
        return p * CAP * dt / (365 days * 10_000);
    }

    function _sumAccrued() internal view returns (uint256 sum) {
        uint256 n = skimmer.recipientCount();
        for (uint256 i; i < n; ++i) {
            sum += skimmer.accrued(skimmer.recipientAt(i));
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                 CONSTRUCTOR                                */
    /* -------------------------------------------------------------------------- */

    function test_constructor_setsConfig() public view {
        assertEq(skimmer.account(), address(account));
        assertEq(address(skimmer.vault()), address(vault));
        assertEq(address(skimmer.asset()), address(usdc));
        assertEq(skimmer.capBps(), CAP);
        assertEq(skimmer.absoluteMaxPerSkim(), ABS_MAX);
        assertEq(skimmer.principal(), 0);
        assertEq(skimmer.lastSkim(), 0);
        assertFalse(skimmer.paused());
        assertEq(skimmer.totalShareBps(), 0);
        assertEq(skimmer.recipientCount(), 0);
    }

    function test_constructor_revertsOnAssetMismatch() public {
        MockERC20 other = new MockERC20();
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.AssetMismatch.selector, address(usdc), address(other)));
        new YieldSkimmer(address(account), IERC4626(address(vault)), IERC20(address(other)), CAP, ABS_MAX);
    }

    function test_constructor_revertsOnZeroCap() public {
        vm.expectRevert(YieldSkimmer.InvalidCap.selector);
        new YieldSkimmer(address(account), IERC4626(address(vault)), IERC20(address(usdc)), 0, ABS_MAX);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(YieldSkimmer.ZeroAddress.selector);
        new YieldSkimmer(address(0), IERC4626(address(vault)), IERC20(address(usdc)), CAP, ABS_MAX);

        vm.expectRevert(YieldSkimmer.ZeroAddress.selector);
        new YieldSkimmer(address(account), IERC4626(address(0)), IERC20(address(usdc)), CAP, ABS_MAX);

        vm.expectRevert(YieldSkimmer.ZeroAddress.selector);
        new YieldSkimmer(address(account), IERC4626(address(vault)), IERC20(address(0)), CAP, ABS_MAX);
    }

    function test_noopModule_isEnableableAndEmpty() public {
        NoopModule noop = new NoopModule();
        assertEq(noop.VERSION(), 1);

        account.setModule(address(noop), true);
        assertTrue(account.isModuleEnabled(address(noop)));
        account.setModule(address(noop), false);
        assertFalse(account.isModuleEnabled(address(noop)));
    }

    /* -------------------------------------------------------------------------- */
    /*                               FIRST SKIM / INIT                            */
    /* -------------------------------------------------------------------------- */

    function test_firstSkim_initializesPrincipalAndMovesNothing() public {
        _add(r1, 10_000, 1 days);
        // Yield that already exists at enable time is principal by definition.
        _setPosition(DEPOSIT + 500e6);

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.Initialized(DEPOSIT + 500e6);
        skimmer.skim();

        assertEq(skimmer.principal(), DEPOSIT + 500e6);
        assertEq(skimmer.lastSkim(), block.timestamp);
        assertEq(usdc.balanceOf(address(skimmer)), 0);
        assertEq(skimmer.accrued(r1), 0);
        assertEq(skimmer.position(), DEPOSIT + 500e6);
        assertEq(account.batchCount(), 0);
    }

    function test_ceilingHelperMatchesLiteral() public pure {
        assertEq(_ceiling(DEPOSIT, 1 days), 82_191_780);
    }

    /* -------------------------------------------------------------------------- */
    /*                                 PLAIN YIELD                                */
    /* -------------------------------------------------------------------------- */

    function test_skim_plainYield_singleRecipient() public {
        _add(r1, 4000, 1 days);
        _firstSkim();

        vm.warp(block.timestamp + 1 days);
        _addYield(10e6); // 10 USDC of yield; ceiling for one day is ~82 USDC

        (uint256 previewYield, uint256 previewTake) = skimmer.previewSkim();
        assertEq(previewYield, 10e6);
        assertEq(previewTake, 4e6);

        skimmer.skim();

        assertEq(usdc.balanceOf(address(skimmer)), 4e6, "module holds the take");
        assertEq(skimmer.accrued(r1), 4e6, "recipient credited");
        // Retained 6 USDC becomes principal; position lost only the 4 USDC taken (+ <= 1 wei of share rounding).
        assertApproxEqAbs(skimmer.principal(), DEPOSIT + 6e6, 1);
        assertGe(skimmer.position(), skimmer.principal());
        assertEq(skimmer.lastSkim(), block.timestamp);
        assertEq(account.batchCount(), 1);
    }

    function test_skim_plainYield_threeRecipients_retainsRemainderAndDust() public {
        _add(r1, 3000, 1 days);
        _add(r2, 2000, 1 days);
        _add(r3, 1000, 1 days);
        _firstSkim();

        vm.warp(block.timestamp + 1 days);
        _addYield(10_000_003); // not divisible by the shares, so rounding dust is exercised

        uint256 yieldAmt = 10_000_003;
        uint256 take = yieldAmt * 6000 / 10_000; // 6_000_001, floor of 6_000_001.8
        assertEq(take, 6_000_001);

        skimmer.skim();

        // Each share floors on its own: 3_000_000 + 2_000_000 + 1_000_000 = 6_000_000, 1 wei of dust in the module.
        assertEq(skimmer.accrued(r1), 3_000_000);
        assertEq(skimmer.accrued(r2), 2_000_000);
        assertEq(skimmer.accrued(r3), 1_000_000);
        assertEq(usdc.balanceOf(address(skimmer)), take, "take landed in the module");
        assertEq(_sumAccrued(), 6_000_000);
        assertEq(usdc.balanceOf(address(skimmer)) - _sumAccrued(), 1, "dust stays, uncredited");

        // The retained share (yield - take = 4_000_002) is folded into principal.
        assertApproxEqAbs(skimmer.principal(), DEPOSIT + yieldAmt - take, 1);
        assertGe(skimmer.position(), skimmer.principal());
    }

    function test_skim_noRecipients_retainsAllYieldAsPrincipal() public {
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);

        skimmer.skim();

        assertEq(account.batchCount(), 0, "no batch when nothing is taken");
        assertEq(usdc.balanceOf(address(skimmer)), 0);
        assertEq(skimmer.principal(), DEPOSIT + 10e6, "all yield is retained as principal");
        assertEq(skimmer.position(), DEPOSIT + 10e6);
    }

    function test_skim_batchHasExactlyTwoCalls() public {
        _add(r1, 10_000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);

        skimmer.skim();

        ISmartVaultModuleManager.Call[] memory calls = account.lastBatch();
        assertEq(calls.length, 2, "exactly two calls");

        assertEq(calls[0].target, address(vault));
        assertEq(calls[0].value, 0);
        assertEq(calls[0].data, abi.encodeCall(IERC4626.withdraw, (10e6, address(account), address(account))));

        assertEq(calls[1].target, address(usdc));
        assertEq(calls[1].value, 0);
        assertEq(calls[1].data, abi.encodeCall(IERC20.transfer, (address(skimmer), 10e6)));
    }

    function test_skim_emitsSkimmedAndCredited() public {
        _add(r1, 4000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 365 days);
        // +25% is exact in the mock's arithmetic (pps 1.25e18), and below the one-year ceiling of 30%.
        _setPosition(DEPOSIT * 125 / 100);
        uint256 yieldAmt = DEPOSIT * 25 / 100; // 25_000 USDC
        uint256 take = yieldAmt * 4000 / 10_000;

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.Credited(r1, take);
        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.Skimmed(DEPOSIT * 125 / 100, yieldAmt, take, DEPOSIT * 125 / 100 - take);
        skimmer.skim();

        assertEq(skimmer.principal(), DEPOSIT * 125 / 100 - take);
        assertEq(skimmer.position(), skimmer.principal());
    }

    /* -------------------------------------------------------------------------- */
    /*                                   RATCHET                                  */
    /* -------------------------------------------------------------------------- */

    function test_ratchet_onSharePriceDrop() public {
        _add(r1, 10_000, 1 days);
        _firstSkim();

        vm.warp(block.timestamp + 1 days);
        _setPosition(90_000e6);

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.Skimmed(90_000e6, 0, 0, 90_000e6);
        skimmer.skim();

        assertEq(skimmer.principal(), 90_000e6, "watermark follows the position down");
        assertEq(usdc.balanceOf(address(skimmer)), 0);
        assertEq(account.batchCount(), 0);
    }

    function test_ratchet_reboundAfterDropIsOnlySkimmableUpToTheCeiling() public {
        _add(r1, 10_000, 1 days);
        _firstSkim();

        vm.warp(block.timestamp + 1 days);
        _setPosition(90_000e6);
        skimmer.skim(); // principal -> 90_000e6

        // The price recovers the whole drop by the next day. 10_000 USDC over the ceiling cannot be yield.
        vm.warp(block.timestamp + 1 days);
        _setPosition(100_000e6);
        skimmer.skim();

        uint256 ceiling = _ceiling(90_000e6, 1 days);
        assertEq(usdc.balanceOf(address(skimmer)), ceiling, "only one ceiling's worth moves");
        assertApproxEqAbs(skimmer.principal(), 100_000e6 - ceiling, 1, "the recovered drop folds into principal");
    }

    function test_ratchet_onAccountWithdrawal() public {
        _add(r1, 10_000, 1 days);
        _firstSkim();

        // The owner withdraws 20k from the vault without telling the module.
        account.exec(address(vault), abi.encodeCall(IERC4626.withdraw, (20_000e6, address(account), address(account))));
        vm.warp(block.timestamp + 1 days);
        assertEq(skimmer.position(), 80_000e6);

        skimmer.skim();

        assertEq(skimmer.principal(), 80_000e6);
        assertEq(usdc.balanceOf(address(skimmer)), 0);
    }

    function test_ratchet_secondPassKeepsPositionAtOrAbovePrincipal() public {
        // Non-round price so the vault's round-up on `withdraw` can leave the position a wei under the watermark.
        _add(r1, 10_000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        vault.setPricePerShare(1.0000123456789e18);
        skimmer.skim();

        assertGe(skimmer.position(), skimmer.principal(), "position >= principal after a skim");
        assertLe(skimmer.position() - skimmer.principal(), 1, "principal sits at most a wei under the position");
    }

    /* -------------------------------------------------------------------------- */
    /*                                  ABSORPTION                                */
    /* -------------------------------------------------------------------------- */

    function test_absorb_largeDepositFoldsIntoPrincipal() public {
        _add(r1, 10_000, 1 days);
        _firstSkim();

        vm.warp(block.timestamp + 1 days);
        _deposit(10_000e6); // an unannounced deposit at par; position is now 110_000e6

        skimmer.skim();

        uint256 ceiling = _ceiling(DEPOSIT, 1 days);
        assertEq(usdc.balanceOf(address(skimmer)), ceiling, "only one ceiling's worth is skimmable");
        assertEq(skimmer.accrued(r1), ceiling);
        // Position is 110_000e6 - ceiling and the watermark equals it: the rest of the deposit is principal.
        assertEq(skimmer.principal(), 110_000e6 - ceiling);
        assertEq(skimmer.position(), skimmer.principal());
    }

    function test_absorb_afterAbsorptionNothingRemainsToSkim() public {
        _add(r1, 10_000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _deposit(10_000e6);
        skimmer.skim();

        uint256 moved = usdc.balanceOf(address(skimmer));
        vm.warp(block.timestamp + 1 days);
        skimmer.skim();

        assertEq(usdc.balanceOf(address(skimmer)), moved, "no yield since, so nothing more moves");
    }

    function test_absorb_withAbsoluteMaxBinding_restOfTheCeilingStaysSkimmable() public {
        _add(r1, 10_000, 1 days);
        vm.prank(address(account));
        skimmer.setCap(CAP, 5e6);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _deposit(10_000e6); // position 110_000e6; the ceiling absorbs everything above 110_000e6 - 82_191_780

        skimmer.skim();

        uint256 ceiling = _ceiling(DEPOSIT, 1 days);
        assertEq(usdc.balanceOf(address(skimmer)), 5e6, "yield is capped by absoluteMaxPerSkim");
        // Only the excess beyond the ceiling is folded into principal; ceiling - 5 USDC is still above the watermark.
        assertEq(skimmer.principal(), 110_000e6 - ceiling);
        assertEq(skimmer.position() - skimmer.principal(), ceiling - 5e6);
    }

    /* -------------------------------------------------------------------------- */
    /*                               ABSOLUTE MAX / CEILING                       */
    /* -------------------------------------------------------------------------- */

    function test_absoluteMax_bindsAndLeftoverIsPickedUpLater() public {
        _add(r1, 10_000, 1 days);
        vm.prank(address(account));
        skimmer.setCap(CAP, 5e6);
        _firstSkim();

        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);
        skimmer.skim();

        assertEq(usdc.balanceOf(address(skimmer)), 5e6, "absoluteMaxPerSkim binds");
        // The other 5 USDC is still above the watermark (less <= 1 wei of share rounding).
        assertApproxEqAbs(skimmer.position() - skimmer.principal(), 5e6, 1);

        vm.warp(block.timestamp + 1 days);
        skimmer.skim();
        assertApproxEqAbs(usdc.balanceOf(address(skimmer)), 10e6, 1, "the next poke takes the leftover");
    }

    function test_ceiling_bindsOnElapsedTime() public {
        _add(r1, 10_000, 1 days);
        _firstSkim();

        vm.warp(block.timestamp + 1 hours);
        _addYield(1000e6); // 1% in an hour is not yield

        skimmer.skim();

        uint256 ceiling = _ceiling(DEPOSIT, 1 hours);
        assertEq(ceiling, 3_424_657);
        assertEq(usdc.balanceOf(address(skimmer)), ceiling);
        assertEq(skimmer.accrued(r1), ceiling);
        // The rest of the 1,000 USDC was absorbed into principal.
        assertApproxEqAbs(skimmer.principal(), DEPOSIT + 1000e6 - ceiling, 1);
    }

    function test_ceiling_twoSkimsInTheSameBlockMoveNothingTheSecondTime() public {
        _add(r1, 10_000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);

        skimmer.skim();
        uint256 moved = usdc.balanceOf(address(skimmer));
        uint256 principalBefore = skimmer.principal();
        assertEq(moved, 10e6);

        (uint256 previewYield, uint256 previewTake) = skimmer.previewSkim();
        assertEq(previewYield, 0);
        assertEq(previewTake, 0);

        skimmer.skim(); // same block, elapsed == 0

        assertEq(usdc.balanceOf(address(skimmer)), moved, "second skim in the same block moves nothing");
        assertEq(skimmer.accrued(r1), moved);
        assertEq(skimmer.principal(), principalBefore, "and the watermark does not move");
    }

    /// @dev Documents a consequence of the PRD rules: elapsed == 0 means ceiling == 0, so any excess left behind by
    ///      `absoluteMaxPerSkim` is absorbed (not skimmed) by an immediate second call.
    function test_ceiling_secondSkimInSameBlockAbsorbsLeftoverFromAbsoluteMax() public {
        _add(r1, 10_000, 1 days);
        vm.prank(address(account));
        skimmer.setCap(CAP, 5e6);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);

        skimmer.skim();
        assertApproxEqAbs(skimmer.position() - skimmer.principal(), 5e6, 1);

        skimmer.skim();

        assertEq(usdc.balanceOf(address(skimmer)), 5e6, "nothing more is moved");
        assertEq(skimmer.position(), skimmer.principal(), "the leftover became principal");
    }

    function test_absoluteMaxZero_recognizesNoYield() public {
        _add(r1, 10_000, 1 days);
        vm.prank(address(account));
        skimmer.setCap(CAP, 0);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);

        skimmer.skim();

        assertEq(usdc.balanceOf(address(skimmer)), 0);
        assertEq(account.batchCount(), 0);
    }

    /* -------------------------------------------------------------------------- */
    /*                                    PULL                                    */
    /* -------------------------------------------------------------------------- */

    function test_pull_paysOnlyTheRecipient_whoeverCalls() public {
        _add(r1, 4000, 1 days);
        _add(r2, 2000, 5 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);
        skimmer.skim();

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.Pulled(r1, 4e6);
        vm.prank(stranger);
        skimmer.pull(r1);

        assertEq(usdc.balanceOf(r1), 4e6, "the recipient receives");
        assertEq(usdc.balanceOf(stranger), 0, "the caller does not");
        assertEq(skimmer.accrued(r1), 0);
        assertEq(skimmer.accrued(r2), 2e6, "others are untouched");
        (,, uint64 lastPull,) = skimmer.recipients(r1);
        assertEq(lastPull, block.timestamp);
    }

    function test_pull_enforcesMinInterval() public {
        _add(r1, 4000, 1 days);
        _firstSkim();

        vm.warp(block.timestamp + 12 hours);
        _addYield(5e6);
        skimmer.skim();
        skimmer.pull(r1); // first pull is allowed immediately

        vm.warp(block.timestamp + 12 hours);
        _addYield(5e6);
        skimmer.skim();

        uint256 availableAt = block.timestamp - 12 hours + 1 days;
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.PullTooSoon.selector, r1, availableAt));
        skimmer.pull(r1);

        vm.warp(availableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.PullTooSoon.selector, r1, availableAt));
        skimmer.pull(r1);

        vm.warp(availableAt); // boundary: exactly minInterval after the last pull is allowed
        skimmer.pull(r1);
        assertEq(skimmer.accrued(r1), 0);
    }

    function test_pull_revertsForNonRecipientAndWhenNothingAccrued() public {
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.NotRecipient.selector, stranger));
        skimmer.pull(stranger);

        _add(r1, 4000, 1 days);
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.NothingToPull.selector, r1));
        skimmer.pull(r1);
    }

    function test_pull_zeroAccruedDoesNotConsumeTheInterval() public {
        _add(r1, 4000, 1 days);
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.NothingToPull.selector, r1));
        skimmer.pull(r1);

        _firstSkim();
        vm.warp(block.timestamp + 1 hours);
        _addYield(1e6);
        skimmer.skim();

        skimmer.pull(r1); // would revert PullTooSoon if the failed attempt had set lastPull
        assertEq(usdc.balanceOf(r1), 400_000);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  RECIPIENTS                                */
    /* -------------------------------------------------------------------------- */

    function test_addRecipient_storesAndEmits() public {
        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.RecipientAdded(r1, 4000, 1 days);
        _add(r1, 4000, 1 days);

        (uint16 share, uint32 interval, uint64 lastPull, uint256 accruedAmt) = skimmer.recipients(r1);
        assertEq(share, 4000);
        assertEq(interval, 1 days);
        assertEq(lastPull, 0);
        assertEq(accruedAmt, 0);
        assertEq(skimmer.totalShareBps(), 4000);
        assertTrue(skimmer.isRecipient(r1));
        assertEq(skimmer.recipientCount(), 1);
        assertEq(skimmer.recipientAt(0), r1);
    }

    function test_addRecipient_reverts() public {
        vm.startPrank(address(account));

        vm.expectRevert(YieldSkimmer.ZeroAddress.selector);
        skimmer.addRecipient(address(0), 1000, 1 days);

        skimmer.addRecipient(r1, 6000, 1 days);
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.RecipientExists.selector, r1));
        skimmer.addRecipient(r1, 1000, 1 days);

        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.ShareOverflow.selector, 10_001));
        skimmer.addRecipient(r2, 4001, 1 days);

        skimmer.addRecipient(r2, 4000, 1 days); // exactly 10_000 is fine
        assertEq(skimmer.totalShareBps(), 10_000);

        vm.stopPrank();
    }

    function test_setRecipient_updatesAndKeepsAccrued() public {
        _add(r1, 4000, 1 days);
        _add(r2, 2000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);
        skimmer.skim();
        assertEq(skimmer.accrued(r1), 4e6);

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.RecipientUpdated(r1, 1000, 7 days);
        vm.prank(address(account));
        skimmer.setRecipient(r1, 1000, 7 days);

        assertEq(skimmer.totalShareBps(), 3000);
        assertEq(skimmer.accrued(r1), 4e6, "accrued survives a share change");

        // Only later skims use the new share.
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);
        skimmer.skim();
        assertEq(skimmer.accrued(r1), 4e6 + 1e6);
    }

    function test_setRecipient_reverts() public {
        _add(r1, 6000, 1 days);
        _add(r2, 4000, 1 days);

        vm.startPrank(address(account));
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.NotRecipient.selector, r3));
        skimmer.setRecipient(r3, 100, 1 days);

        // The bound is checked against the total without r1's old share: 4000 + 6001 > 10_000.
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.ShareOverflow.selector, 10_001));
        skimmer.setRecipient(r1, 6001, 1 days);

        skimmer.setRecipient(r1, 6000, 2 days); // unchanged share, new interval
        vm.stopPrank();
    }

    function test_removeRecipient_forfeitsAccruedToAccount() public {
        _add(r1, 4000, 1 days);
        _add(r2, 2000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);
        skimmer.skim();
        assertEq(skimmer.accrued(r1), 4e6);
        assertEq(usdc.balanceOf(address(account)), 0);

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.RecipientRemoved(r1, 4e6);
        vm.prank(address(account));
        skimmer.removeRecipient(r1);

        assertEq(usdc.balanceOf(address(account)), 4e6, "forfeited accrued goes back to the account");
        assertEq(usdc.balanceOf(address(skimmer)), 2e6, "only r2's accrued remains");
        assertEq(usdc.balanceOf(r1), 0);
        assertEq(skimmer.totalShareBps(), 2000);
        assertFalse(skimmer.isRecipient(r1));
        assertEq(skimmer.recipientCount(), 1);
        assertEq(skimmer.recipientAt(0), r2);
        assertEq(skimmer.accrued(r1), 0);

        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.NotRecipient.selector, r1));
        skimmer.pull(r1);

        // Removal frees the share and a re-added recipient starts clean.
        _add(r1, 8000, 1 days);
        (,, uint64 lastPull, uint256 accruedAmt) = skimmer.recipients(r1);
        assertEq(lastPull, 0);
        assertEq(accruedAmt, 0);
    }

    function test_removeRecipient_withNothingAccruedAndSwapAndPop() public {
        _add(r1, 1000, 1 days);
        _add(r2, 1000, 1 days);
        _add(r3, 1000, 1 days);

        vm.prank(address(account));
        skimmer.removeRecipient(r1);

        assertEq(skimmer.recipientCount(), 2);
        assertTrue(skimmer.isRecipient(r2));
        assertTrue(skimmer.isRecipient(r3));
        assertEq(skimmer.totalShareBps(), 2000);
        assertEq(usdc.balanceOf(address(account)), 0);

        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.NotRecipient.selector, r1));
        skimmer.removeRecipient(r1);
    }

    function test_removedRecipientNoLongerEarnsFromLaterSkims() public {
        _add(r1, 4000, 1 days);
        _add(r2, 2000, 1 days);
        _firstSkim();
        vm.prank(address(account));
        skimmer.removeRecipient(r1);

        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);
        skimmer.skim();

        assertEq(skimmer.accrued(r1), 0);
        assertEq(skimmer.accrued(r2), 2e6);
        assertEq(usdc.balanceOf(address(skimmer)), 2e6, "take uses the new total share");
    }

    /* -------------------------------------------------------------------------- */
    /*                                  ADMIN: CAP                                */
    /* -------------------------------------------------------------------------- */

    function test_setCap_updatesAndEmits() public {
        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.CapUpdated(65_535, 123);
        vm.prank(address(account));
        skimmer.setCap(65_535, 123);

        assertEq(skimmer.capBps(), 65_535);
        assertEq(skimmer.absoluteMaxPerSkim(), 123);
    }

    function test_setCap_revertsOnZeroCap() public {
        vm.prank(address(account));
        vm.expectRevert(YieldSkimmer.InvalidCap.selector);
        skimmer.setCap(0, 123);
    }

    /* -------------------------------------------------------------------------- */
    /*                             ADMIN: RESET PRINCIPAL                         */
    /* -------------------------------------------------------------------------- */

    function test_resetPrincipal_setsPositionAndClock() public {
        _firstSkim();
        vm.warp(block.timestamp + 3 days);
        _setPosition(DEPOSIT + 777e6);

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.PrincipalReset(DEPOSIT + 777e6);
        vm.prank(address(account));
        skimmer.resetPrincipal();

        assertEq(skimmer.principal(), DEPOSIT + 777e6);
        assertEq(skimmer.lastSkim(), block.timestamp);
        (uint256 y,) = skimmer.previewSkim();
        assertEq(y, 0, "the reset yield is not skimmable");
    }

    function test_resetPrincipal_alsoLowersPrincipalAndInitializes() public {
        vm.prank(address(account));
        skimmer.resetPrincipal(); // before any skim: acts as initialization
        assertEq(skimmer.principal(), DEPOSIT);
        assertGt(skimmer.lastSkim(), 0);

        _setPosition(DEPOSIT / 2);
        vm.prank(address(account));
        skimmer.resetPrincipal();
        assertEq(skimmer.principal(), DEPOSIT / 2);
    }

    /* -------------------------------------------------------------------------- */
    /*                                    PAUSE                                   */
    /* -------------------------------------------------------------------------- */

    function test_pause_blocksSkimAndPullButNotAdmin() public {
        _add(r1, 4000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);
        skimmer.skim();

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.Paused();
        vm.prank(address(account));
        skimmer.pause();
        assertTrue(skimmer.paused());

        vm.expectRevert(YieldSkimmer.SkimmerPaused.selector);
        skimmer.skim();
        vm.expectRevert(YieldSkimmer.SkimmerPaused.selector);
        skimmer.pull(r1);

        // Admin keeps working while paused.
        vm.prank(address(account));
        skimmer.setCap(CAP, 1);

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.Unpaused();
        vm.prank(address(account));
        skimmer.unpause();
        assertFalse(skimmer.paused());

        skimmer.pull(r1);
        assertEq(usdc.balanceOf(r1), 4e6);
    }

    /* -------------------------------------------------------------------------- */
    /*                                   DRAIN TO                                 */
    /* -------------------------------------------------------------------------- */

    function test_drainTo_sendsWholeBalanceAndZeroesAccrued() public {
        _add(r1, 3000, 1 days);
        _add(r2, 2000, 1 days);
        _add(r3, 1000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10_000_003); // leaves 1 wei of uncredited dust in the module
        skimmer.skim();
        assertEq(usdc.balanceOf(address(skimmer)), 6_000_001);

        vm.prank(address(account));
        skimmer.pause(); // drain must work while paused

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.Drained(address(account), 6_000_001);
        vm.prank(address(account));
        skimmer.drainTo(address(account));

        assertEq(usdc.balanceOf(address(account)), 6_000_001);
        assertEq(usdc.balanceOf(address(skimmer)), 0);
        assertEq(skimmer.accrued(r1), 0);
        assertEq(skimmer.accrued(r2), 0);
        assertEq(skimmer.accrued(r3), 0);

        vm.prank(address(account));
        skimmer.unpause();
        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.NothingToPull.selector, r1));
        skimmer.pull(r1);
    }

    function test_drainTo_revertsOnZeroAddressAndAllowsEmptyDrain() public {
        vm.startPrank(address(account));
        vm.expectRevert(YieldSkimmer.ZeroAddress.selector);
        skimmer.drainTo(address(0));

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.Drained(r1, 0);
        skimmer.drainTo(r1);
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                                ACCESS CONTROL                              */
    /* -------------------------------------------------------------------------- */

    function test_admin_revertsForEveryNonAccountCaller() public {
        bytes[8] memory calls = [
            abi.encodeCall(YieldSkimmer.addRecipient, (r1, 1000, 1 days)),
            abi.encodeCall(YieldSkimmer.setRecipient, (r1, 1000, 1 days)),
            abi.encodeCall(YieldSkimmer.removeRecipient, (r1)),
            abi.encodeCall(YieldSkimmer.setCap, (CAP, 1)),
            abi.encodeCall(YieldSkimmer.resetPrincipal, ()),
            abi.encodeCall(YieldSkimmer.pause, ()),
            abi.encodeCall(YieldSkimmer.unpause, ()),
            abi.encodeCall(YieldSkimmer.drainTo, (stranger))
        ];

        address[3] memory callers = [stranger, r1, address(this)];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool ok, bytes memory ret) = address(skimmer).call(calls[i]);
                assertFalse(ok, "admin call must revert");
                assertEq(ret, abi.encodeWithSelector(YieldSkimmer.NotAccount.selector));
            }
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                PREVIEW SKIM                                */
    /* -------------------------------------------------------------------------- */

    function test_previewSkim_zeroBeforeFirstSkim() public {
        _add(r1, 4000, 1 days);
        _setPosition(DEPOSIT + 500e6);
        (uint256 y, uint256 t) = skimmer.previewSkim();
        assertEq(y, 0);
        assertEq(t, 0);
    }

    function test_previewSkim_matchesWhatSkimThenMoves() public {
        _add(r1, 4000, 1 days);
        _add(r2, 1000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 365 days);
        _setPosition(DEPOSIT * 125 / 100);

        (uint256 previewYield, uint256 previewTake) = skimmer.previewSkim();
        assertEq(previewYield, 25_000e6);
        assertEq(previewTake, 12_500e6);

        uint256 balanceBefore = usdc.balanceOf(address(skimmer));
        uint256 positionBefore = skimmer.position();

        vm.expectEmit(address(skimmer));
        emit YieldSkimmer.Skimmed(positionBefore, previewYield, previewTake, positionBefore - previewTake);
        skimmer.skim();

        assertEq(usdc.balanceOf(address(skimmer)) - balanceBefore, previewTake);
        assertEq(skimmer.accrued(r1) + skimmer.accrued(r2), previewTake);
        assertEq(positionBefore - skimmer.position(), previewTake);
    }

    function test_previewSkim_reflectsAbsorptionAndCaps() public {
        _add(r1, 10_000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _deposit(10_000e6);

        (uint256 y, uint256 t) = skimmer.previewSkim();
        assertEq(y, _ceiling(DEPOSIT, 1 days));
        assertEq(t, y);

        skimmer.skim();
        assertEq(usdc.balanceOf(address(skimmer)), t);
    }

    /* -------------------------------------------------------------------------- */
    /*                              FAILURE PROPAGATION                           */
    /* -------------------------------------------------------------------------- */

    function test_skim_vaultWithdrawRevertPropagatesWithNoPartialState() public {
        _add(r1, 4000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);

        vault.setWithdrawReverts(true);

        uint256 principalBefore = skimmer.principal();
        uint256 lastSkimBefore = skimmer.lastSkim();

        vm.expectRevert(MockVault.LiquidityShortfall.selector);
        skimmer.skim();

        assertEq(skimmer.principal(), principalBefore);
        assertEq(skimmer.lastSkim(), lastSkimBefore);
        assertEq(skimmer.accrued(r1), 0, "no credit without a transfer");
        assertEq(usdc.balanceOf(address(skimmer)), 0);
        assertEq(skimmer.position(), DEPOSIT + 10e6);

        // The next poke retries and succeeds once liquidity is back, taking the full yield.
        vault.setWithdrawReverts(false);
        skimmer.skim();
        assertEq(skimmer.accrued(r1), 4e6);
        assertEq(usdc.balanceOf(address(skimmer)), 4e6);
    }

    function test_skim_revertsWhenModuleIsDisabledOnTheAccount() public {
        _add(r1, 4000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);

        account.setModule(address(skimmer), false);
        vm.expectRevert(MockAccount.NotModule.selector);
        skimmer.skim();
    }

    function test_skim_revertsIfTheBatchDeliversLessThanTheTake() public {
        _add(r1, 4000, 1 days);
        _firstSkim();
        vm.warp(block.timestamp + 1 days);
        _addYield(10e6);

        // Fee-on-transfer asset with idle balance on the account so the second call does not itself revert.
        usdc.mint(address(account), 1000e6);
        usdc.setFeeBps(100);

        vm.expectRevert(abi.encodeWithSelector(YieldSkimmer.TransferShortfall.selector, 4e6, 4e6 * 99 / 100));
        skimmer.skim();
    }

    /* -------------------------------------------------------------------------- */
    /*                                    FUZZ                                    */
    /* -------------------------------------------------------------------------- */

    /// @dev One skim after arbitrary yield / deposit / withdrawal / time / caps / shares:
    ///      take <= min(ceiling, absoluteMax); position >= principal; credited <= skimmed;
    ///      principal only drops via the ratchet (plus <= 1 wei of share rounding).
    function testFuzz_skim_respectsBoundsAndInvariants(
        uint256 priceBps,
        uint256 dt,
        uint16 cap,
        uint256 absMax,
        uint16 share1,
        uint16 share2
    )
        public
    {
        cap = uint16(bound(cap, 1, type(uint16).max));
        absMax = bound(absMax, 0, 2_000_000e6);
        dt = bound(dt, 0, 400 days);
        priceBps = bound(priceBps, 5000, 30_000); // 0.5x .. 3x
        share1 = uint16(bound(share1, 0, 10_000));
        share2 = uint16(bound(share2, 0, 10_000 - share1));

        vm.startPrank(address(account));
        skimmer.setCap(cap, absMax);
        skimmer.addRecipient(r1, share1, 0);
        skimmer.addRecipient(r2, share2, 0);
        vm.stopPrank();

        _firstSkim();
        uint256 principalBefore = skimmer.principal();
        vm.warp(block.timestamp + dt);
        _setPosition(DEPOSIT * priceBps / 10_000);

        uint256 assetsBefore = skimmer.position();
        uint256 expectedPrincipal = Math.min(principalBefore, assetsBefore); // the ratchet
        uint256 ceiling = expectedPrincipal * cap * dt / (365 days * 10_000);
        uint256 bound_ = Math.min(ceiling, absMax);

        (uint256 previewYield, uint256 previewTake) = skimmer.previewSkim();
        skimmer.skim();

        uint256 moved = usdc.balanceOf(address(skimmer));
        assertEq(moved, previewTake, "preview == moved");
        assertLe(previewYield, bound_, "yield <= min(ceiling, absoluteMax)");
        assertLe(moved, bound_, "take <= min(ceiling, absoluteMax)");
        assertLe(_sumAccrued(), moved, "credited <= skimmed");
        assertEq(moved, previewYield * (uint256(share1) + share2) / 10_000);

        assertGe(skimmer.position(), skimmer.principal(), "position >= principal after skim");
        if (assetsBefore >= principalBefore) {
            assertGe(skimmer.principal() + 1, principalBefore, "a skim never lowers principal beyond 1 wei rounding");
        } else {
            assertLe(skimmer.principal(), assetsBefore, "ratchet follows the position");
        }
    }
}
