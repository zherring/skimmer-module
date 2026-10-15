// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { YieldSkimmer } from "../../src/YieldSkimmer.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockVault } from "../mocks/MockVault.sol";
import { MockAccount } from "../mocks/MockAccount.sol";

/// @notice Drives the skimmer through random sequences of deposits, withdrawals, price moves, time, skims, pulls and
///         admin changes, and records ghost variables that the invariant test asserts on.
/// @dev Violations are recorded as booleans instead of `assert`ed here: with `fail_on_revert = false` a failing assert
///      inside a handler would just look like a revert and be ignored.
contract SkimmerHandler is Test {
    /// @dev The vault rounds shares up on `withdraw` and the position rounds down, so right after a skim the position
    ///      can sit at most this many wei under the pre-skim idealized value.
    uint256 internal constant ROUNDING = 1;

    MockERC20 public usdc;
    MockVault public vault;
    MockAccount public account;
    YieldSkimmer public skimmer;

    address[] internal _actors;

    // Ghost variables.
    uint256 public ghostTotalSkimmed; // sum of `take` over all skims (module balance deltas)
    uint256 public ghostTotalCredited; // sum of accrued deltas caused by skims
    uint256 public ghostSkims; // skims that were not the initializing call
    uint256 public ghostLastCeiling; // independently computed ceiling of the most recent skim
    uint256 public ghostLastTake;

    // Violation flags, one per invariant.
    bool public violatedPrincipalNotPosition; // (1)
    bool public violatedPrincipalLowered; // (2)
    bool public violatedTakeAboveBound; // (4)
    bool public violatedPausedSkim;
    bool public violatedPullRecipient;
    bool public violatedPartialState;
    bool public violatedInit;
    bool public violatedLiveness; // skim reverted although the vault could serve it
    bool public violatedPreview; // previewSkim disagreed with what skim moved
    bool public violatedModel; // skim disagreed with a from-scratch restatement of the PRD mechanics
    bool public violatedNoOp; // a skim with nothing new to recognize moved something

    mapping(bytes32 => uint256) public calls;

    constructor(MockERC20 usdc_, MockVault vault_, MockAccount account_, YieldSkimmer skimmer_) {
        usdc = usdc_;
        vault = vault_;
        account = account_;
        skimmer = skimmer_;
        for (uint256 i; i < 5; ++i) {
            _actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                           POSITION AND TIME ACTIONS                        */
    /* -------------------------------------------------------------------------- */

    /// @dev An unannounced deposit: mint shares to the account.
    function deposit(uint256 amount) external {
        calls["deposit"]++;
        amount = bound(amount, 1e6, 50_000e6);
        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, address(account));
    }

    /// @dev The owner withdraws part of the position without telling the module.
    function accountWithdraws(uint256 amount) external {
        calls["accountWithdraws"]++;
        uint256 pos = skimmer.position();
        if (pos == 0 || vault.withdrawReverts()) return;
        amount = bound(amount, 0, pos);
        vm.prank(address(account));
        vault.withdraw(amount, address(account), address(account));
    }

    /// @dev Plain interest: up to +5%.
    function sharePriceUp(uint256 bps) external {
        calls["sharePriceUp"]++;
        _movePrice(true, bound(bps, 0, 500));
    }

    /// @dev A jump that the rate ceiling should refuse to call yield: up to +100%.
    function sharePriceJump(uint256 bps) external {
        calls["sharePriceJump"]++;
        _movePrice(true, bound(bps, 0, 10_000));
    }

    /// @dev A vault loss: up to -50%.
    function sharePriceDown(uint256 bps) external {
        calls["sharePriceDown"]++;
        _movePrice(false, bound(bps, 0, 5000));
    }

    function warp(uint256 dt) external {
        calls["warp"]++;
        vm.warp(block.timestamp + bound(dt, 0, 60 days));
    }

    /// @dev Toggles the vault's ability to serve withdrawals (liquidity shortfall).
    function setLiquidity(uint256 seed) external {
        calls["setLiquidity"]++;
        vault.setWithdrawReverts(seed % 8 == 0);
    }

    function _movePrice(bool up, uint256 bps) internal {
        uint256 pps = vault.pricePerShare();
        uint256 next = up ? pps * (10_000 + bps) / 10_000 : pps * (10_000 - bps) / 10_000;
        if (next < 0.05e18) next = 0.05e18;
        if (next > 100e18) next = 100e18;
        vault.setPricePerShare(next);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  SKIM / PULL                               */
    /* -------------------------------------------------------------------------- */

    /// @dev Everything read before a skim that the checks afterwards need.
    struct Snapshot {
        uint256 lastSkim;
        uint256 principal;
        uint256 assets;
        uint256 moduleBalance;
        uint256 accrued;
        uint256 capBps;
        uint256 absoluteMax;
        uint256 totalShareBps;
        uint256 previewTake;
    }

    function skim() external {
        calls["skim"]++;

        if (skimmer.paused()) {
            try skimmer.skim() {
                violatedPausedSkim = true;
            } catch { }
            return;
        }

        Snapshot memory b = _snapshot();

        try skimmer.skim() { }
        catch {
            // The only legitimate reason to revert is a withdrawal the vault cannot serve.
            if (!(vault.withdrawReverts() && b.previewTake > 0)) violatedLiveness = true;
            // A reverted skim must leave no trace.
            if (
                skimmer.lastSkim() != b.lastSkim || skimmer.principal() != b.principal
                    || usdc.balanceOf(address(skimmer)) != b.moduleBalance || _sumAccrued() != b.accrued
            ) violatedPartialState = true;
            return;
        }

        if (b.lastSkim == 0) {
            // Initializing call: record the watermark, move nothing.
            if (
                skimmer.principal() != b.assets || usdc.balanceOf(address(skimmer)) != b.moduleBalance
                    || skimmer.lastSkim() != block.timestamp
            ) violatedInit = true;
            return;
        }

        _checkSkim(b);
    }

    function _snapshot() internal returns (Snapshot memory b) {
        // The preview is a view over the same position data and must never revert, whatever the position or price.
        try skimmer.previewSkim() returns (uint256, uint256 previewTake_) {
            b.previewTake = previewTake_;
        } catch {
            violatedLiveness = true;
        }
        b.lastSkim = skimmer.lastSkim();
        b.principal = skimmer.principal();
        b.assets = skimmer.position();
        b.moduleBalance = usdc.balanceOf(address(skimmer));
        b.accrued = _sumAccrued();
        b.capBps = skimmer.capBps();
        b.absoluteMax = skimmer.absoluteMaxPerSkim();
        b.totalShareBps = skimmer.totalShareBps();
    }

    function _checkSkim(Snapshot memory b) internal {
        ghostSkims++;
        uint256 principalAfter = skimmer.principal();
        uint256 positionAfter = skimmer.position();
        uint256 take = usdc.balanceOf(address(skimmer)) - b.moduleBalance;
        ghostTotalSkimmed += take;
        ghostTotalCredited += _sumAccrued() - b.accrued;

        // (1) After every skim the watermark IS the position (re-read after the batch, so exact).
        if (positionAfter != principalAfter) violatedPrincipalNotPosition = true;

        // (2) A skim lowers principal only through the ratchet: either the position was already below it, or the
        // vault's round-up on `withdraw` shaved a wei off `assets - take`. It never ends above the pre-skim position.
        if (principalAfter < b.principal) {
            bool ratchet = b.assets < b.principal;
            bool rounding = principalAfter == positionAfter && b.principal - principalAfter <= ROUNDING;
            if (!ratchet && !rounding) violatedPrincipalLowered = true;
        }
        if (principalAfter > b.assets) violatedPrincipalLowered = true;

        // (4) A skim moves at most min(ceiling, absoluteMaxPerSkim), with the ceiling restated here from scratch.
        uint256 p = b.principal < b.assets ? b.principal : b.assets; // step 2: ratchet
        uint256 ceiling = p * b.capBps * (block.timestamp - b.lastSkim) / (365 days * 10_000);
        uint256 limit = ceiling < b.absoluteMax ? ceiling : b.absoluteMax;
        if (take > limit) violatedTakeAboveBound = true;
        ghostLastCeiling = ceiling;
        ghostLastTake = take;

        if (take != b.previewTake) violatedPreview = true;

        // Reference model, restated literally from the PRD rules rather than shared with the contract: yield is
        // min(position - ratcheted principal, ceiling, absoluteMax); what stays in the vault is the new principal.
        uint256 modelYield = b.assets - p;
        if (modelYield > ceiling) modelYield = ceiling;
        if (modelYield > b.absoluteMax) modelYield = b.absoluteMax;
        uint256 modelTake = modelYield * b.totalShareBps / 10_000;
        uint256 modelPrincipal = b.assets - modelTake;
        if (take != modelTake) violatedModel = true;
        if (skimmer.lastSkim() != block.timestamp) violatedModel = true;
        // The vault's share rounding may shave at most a wei off the model; with nothing taken it must be exact.
        if (principalAfter > modelPrincipal || modelPrincipal - principalAfter > ROUNDING) violatedModel = true;
        if (modelTake == 0 && principalAfter != b.assets) violatedModel = true;

        // A skim in the same block as the previous one, with the position untouched since, is a true no-op.
        if (b.lastSkim == block.timestamp && b.assets == b.principal) {
            if (take != 0 || _sumAccrued() != b.accrued || principalAfter != b.principal) violatedNoOp = true;
        }
    }

    function pull(uint256 recipientSeed, uint256 callerSeed) external {
        calls["pull"]++;
        uint256 n = skimmer.recipientCount();
        if (n == 0) return;

        address r = skimmer.recipientAt(recipientSeed % n);
        address caller = _actors[callerSeed % _actors.length];
        uint256 owed = skimmer.accrued(r);
        uint256 recipientBefore = usdc.balanceOf(r);
        uint256 callerBefore = usdc.balanceOf(caller);
        uint256 moduleBefore = usdc.balanceOf(address(skimmer));

        vm.prank(caller);
        try skimmer.pull(r) {
            if (skimmer.paused() || owed == 0) violatedPullRecipient = true;
            if (usdc.balanceOf(r) != recipientBefore + owed) violatedPullRecipient = true;
            if (usdc.balanceOf(address(skimmer)) != moduleBefore - owed) violatedPullRecipient = true;
            if (caller != r && usdc.balanceOf(caller) != callerBefore) violatedPullRecipient = true;
            if (skimmer.accrued(r) != 0) violatedPullRecipient = true;
        } catch { }
    }

    /* -------------------------------------------------------------------------- */
    /*                                    ADMIN                                   */
    /* -------------------------------------------------------------------------- */

    function addRecipient(uint256 actorSeed, uint256 share, uint256 interval) external {
        calls["addRecipient"]++;
        address r = _actors[actorSeed % _actors.length];
        if (skimmer.isRecipient(r)) return;

        share = bound(share, 0, 10_000 - skimmer.totalShareBps());
        interval = bound(interval, 0, 7 days);
        vm.prank(address(account));
        skimmer.addRecipient(r, SafeCast.toUint16(share), SafeCast.toUint32(interval));
    }

    function setRecipient(uint256 seed, uint256 share, uint256 interval) external {
        calls["setRecipient"]++;
        uint256 n = skimmer.recipientCount();
        if (n == 0) return;

        address r = skimmer.recipientAt(seed % n);
        (uint16 current,,,) = skimmer.recipients(r);
        share = bound(share, 0, 10_000 - skimmer.totalShareBps() + current);
        interval = bound(interval, 0, 7 days);
        vm.prank(address(account));
        skimmer.setRecipient(r, SafeCast.toUint16(share), SafeCast.toUint32(interval));
    }

    function removeRecipient(uint256 seed) external {
        calls["removeRecipient"]++;
        uint256 n = skimmer.recipientCount();
        if (n == 0) return;

        address r = skimmer.recipientAt(seed % n); // resolve before pranking: the prank covers only the next call
        vm.prank(address(account));
        skimmer.removeRecipient(r);
    }

    function setCap(uint256 capBps, uint256 absMax) external {
        calls["setCap"]++;
        capBps = bound(capBps, 1, 6000);
        absMax = bound(absMax, 0, 5000e6);
        vm.prank(address(account));
        skimmer.setCap(SafeCast.toUint16(capBps), absMax);
    }

    function resetPrincipal() external {
        calls["resetPrincipal"]++;
        vm.prank(address(account));
        skimmer.resetPrincipal();
    }

    function pause() external {
        calls["pause"]++;
        vm.prank(address(account));
        skimmer.pause();
    }

    function unpause() external {
        calls["unpause"]++;
        vm.prank(address(account));
        skimmer.unpause();
    }

    function drain() external {
        calls["drain"]++;
        vm.prank(address(account));
        skimmer.drainTo(address(account));
    }

    /* -------------------------------------------------------------------------- */
    /*                                    VIEWS                                   */
    /* -------------------------------------------------------------------------- */

    function sumAccrued() external view returns (uint256) {
        return _sumAccrued();
    }

    function sumShareBps() external view returns (uint256 sum) {
        uint256 n = skimmer.recipientCount();
        for (uint256 i; i < n; ++i) {
            (uint16 share,,,) = skimmer.recipients(skimmer.recipientAt(i));
            sum += share;
        }
    }

    function _sumAccrued() internal view returns (uint256 sum) {
        uint256 n = skimmer.recipientCount();
        for (uint256 i; i < n; ++i) {
            sum += skimmer.accrued(skimmer.recipientAt(i));
        }
    }
}

contract YieldSkimmerInvariantTest is StdInvariant, Test {
    MockERC20 internal usdc;
    MockVault internal vault;
    MockAccount internal account;
    YieldSkimmer internal skimmer;
    SkimmerHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);

        usdc = new MockERC20();
        vault = new MockVault(usdc);
        account = new MockAccount();
        skimmer = new YieldSkimmer(address(account), IERC4626(address(vault)), IERC20(address(usdc)), 3000, 50e6);
        account.setModule(address(skimmer), true);

        // Seed position: 100k USDC.
        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, address(account));

        handler = new SkimmerHandler(usdc, vault, account, skimmer);

        // Start from a live configuration so that random sequences reach real skims quickly: two recipients and an
        // initialized watermark. The handler can still add, change, remove, pause and reset from here.
        vm.startPrank(address(account));
        skimmer.addRecipient(makeAddr("actor0"), 4000, 1 days);
        skimmer.addRecipient(makeAddr("actor1"), 2000, 0);
        vm.stopPrank();
        skimmer.skim();

        // Every action once, plus extra weight on the ones that drive skims (skim, time, interest).
        bytes4[] memory selectors = new bytes4[](23);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.accountWithdraws.selector;
        selectors[2] = handler.sharePriceUp.selector;
        selectors[3] = handler.sharePriceJump.selector;
        selectors[4] = handler.sharePriceDown.selector;
        selectors[5] = handler.warp.selector;
        selectors[6] = handler.setLiquidity.selector;
        selectors[7] = handler.skim.selector;
        selectors[8] = handler.pull.selector;
        selectors[9] = handler.addRecipient.selector;
        selectors[10] = handler.setRecipient.selector;
        selectors[11] = handler.removeRecipient.selector;
        selectors[12] = handler.setCap.selector;
        selectors[13] = handler.resetPrincipal.selector;
        selectors[14] = handler.pause.selector;
        selectors[15] = handler.unpause.selector;
        selectors[16] = handler.drain.selector;
        selectors[17] = handler.skim.selector;
        selectors[18] = handler.skim.selector;
        selectors[19] = handler.warp.selector;
        selectors[20] = handler.warp.selector;
        selectors[21] = handler.sharePriceUp.selector;
        selectors[22] = handler.sharePriceUp.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @dev (3) Total credited to recipients <= total skimmed, always.
    function invariant_creditedNeverExceedsSkimmed() public view {
        assertLe(handler.ghostTotalCredited(), handler.ghostTotalSkimmed());
    }

    /// @dev (1) After every skim the watermark is exactly the position.
    function invariant_principalEqualsPositionAfterEverySkim() public view {
        assertFalse(handler.violatedPrincipalNotPosition());
    }

    /// @dev A second skim in the same block, with nothing changed in between, moves and credits nothing.
    function invariant_sameBlockSkimIsANoOp() public view {
        assertFalse(handler.violatedNoOp());
    }

    /// @dev (2) A skim only lowers principal through the ratchet (plus a wei of vault share rounding), and never lifts
    ///      it above the position it read.
    function invariant_principalOnlyRatchetsDown() public view {
        assertFalse(handler.violatedPrincipalLowered());
    }

    /// @dev (4) Every skim moves at most min(ceiling, absoluteMaxPerSkim), with the ceiling recomputed independently.
    function invariant_skimNeverExceedsCeilingOrAbsoluteMax() public view {
        assertFalse(handler.violatedTakeAboveBound());
        assertLe(handler.ghostLastTake(), handler.ghostLastCeiling());
    }

    /// @dev The module can always pay every recipient what it has been credited.
    function invariant_moduleBalanceCoversAccrued() public view {
        assertGe(usdc.balanceOf(address(skimmer)), handler.sumAccrued());
    }

    function invariant_shareBpsAreConsistent() public view {
        assertEq(skimmer.totalShareBps(), handler.sumShareBps());
        assertLe(skimmer.totalShareBps(), 10_000);
    }

    function invariant_pausedSkimNeverSucceeds() public view {
        assertFalse(handler.violatedPausedSkim());
    }

    function invariant_pullOnlyPaysTheRecipient() public view {
        assertFalse(handler.violatedPullRecipient());
    }

    function invariant_revertedSkimLeavesNoTrace() public view {
        assertFalse(handler.violatedPartialState());
    }

    /// @dev Outside a liquidity shortfall a skim is always callable, whatever the position, price or parameters.
    function invariant_skimNeverRevertsWhenVaultIsLiquid() public view {
        assertFalse(handler.violatedLiveness());
    }

    function invariant_previewSkimMatchesSkim() public view {
        assertFalse(handler.violatedPreview());
    }

    /// @dev Skim matches an independent restatement of the mechanics (take, and everything left in the vault is principal).
    function invariant_skimMatchesReferenceModel() public view {
        assertFalse(handler.violatedModel());
    }

    function invariant_firstSkimOnlyInitializes() public view {
        assertFalse(handler.violatedInit());
    }

    /// @dev The module is never left holding vault shares or any asset it was not credited or left as dust.
    function invariant_moduleHoldsNoVaultShares() public view {
        assertEq(vault.balanceOf(address(skimmer)), 0);
    }

    function afterInvariant() public view {
        console2.log("skims (non-init):", handler.ghostSkims());
        console2.log("total skimmed:", handler.ghostTotalSkimmed());
        console2.log("total credited:", handler.ghostTotalCredited());
        string[17] memory names = [
            "deposit",
            "accountWithdraws",
            "sharePriceUp",
            "sharePriceJump",
            "sharePriceDown",
            "warp",
            "setLiquidity",
            "skim",
            "pull",
            "addRecipient",
            "setRecipient",
            "removeRecipient",
            "setCap",
            "resetPrincipal",
            "pause",
            "unpause",
            "drain"
        ];
        for (uint256 i; i < names.length; ++i) {
            console2.log(names[i], handler.calls(bytes32(bytes(names[i]))));
        }
    }
}
