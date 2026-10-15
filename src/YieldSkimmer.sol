// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISmartVaultModuleManager } from "./interfaces/ISmartVaultModuleManager.sol";

/// @title YieldSkimmer
/// @notice A Splits SmartVault module that moves realized yield, and only yield, out of one ERC-4626 position held by
///         one account, and credits it to recipients by share. Principal is a self-healing watermark: it ratchets
///         down when the position falls, absorbs inflows that are too large to be yield, and absorbs the share of
///         yield that is not skimmed. See the PRD ("Part 1 - Yield Skimmer module") for the full rationale.
/// @dev The only calls this contract ever makes from the account are exactly two, in one batch:
///      `vault.withdraw(take, account, account)` and `asset.transfer(address(this), take)`. There is no generic
///      execute passthrough and no owner; every admin function is `onlyAccount`. `account`, `vault` and `asset` are
///      immutable. All amounts are in underlying-asset units.
contract YieldSkimmer {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /* -------------------------------------------------------------------------- */
    /*                                   TYPES                                    */
    /* -------------------------------------------------------------------------- */

    /// @notice Per-recipient configuration and balance.
    struct Recipient {
        /// @dev Share of every skim's yield credited to this recipient, in basis points.
        uint16 shareBps;
        /// @dev Minimum seconds between `pull` calls.
        uint32 minInterval;
        /// @dev Timestamp of the last successful `pull`; 0 before the first.
        uint64 lastPull;
        /// @dev Asset credited but not yet pulled. Held by this contract.
        uint256 accrued;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 CONSTANTS                                  */
    /* -------------------------------------------------------------------------- */

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @dev `365 days * BPS`, the divisor of the rate ceiling.
    uint256 internal constant YEAR_BPS = 365 days * BPS;

    /* -------------------------------------------------------------------------- */
    /*                                 IMMUTABLES                                 */
    /* -------------------------------------------------------------------------- */

    /// @notice The endowment SmartVault whose position is skimmed. Also the only admin.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable account;

    /// @notice The ERC-4626 vault (Morpho V2 wrapper) the account holds shares of.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC4626 public immutable vault;

    /// @notice The vault's underlying asset (USDC).
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable asset;

    /* -------------------------------------------------------------------------- */
    /*                                   STATE                                    */
    /* -------------------------------------------------------------------------- */

    /// @notice The watermark. Position above it is yield; position at or below it is endowment capital.
    uint256 public principal;

    /// @notice Timestamp of the last skim (or reset). 0 until the first `skim` initializes the watermark.
    uint256 public lastSkim;

    /// @notice Annualized rate ceiling in basis points (3,000 = 30% APR). Bites only on money that is not yield.
    uint16 public capBps;

    /// @notice Hard cap on the yield recognized by a single skim.
    uint256 public absoluteMaxPerSkim;

    /// @notice Whether `skim` and `pull` are stopped.
    bool public paused;

    /// @notice Sum of every recipient's `shareBps`. Always <= 10,000; the remainder compounds in the vault.
    uint256 public totalShareBps;

    /// @notice Recipient configuration and accrued balances. Zeroed for addresses that are not recipients.
    mapping(address recipient => Recipient) public recipients;

    EnumerableSet.AddressSet private _recipientSet;

    /* -------------------------------------------------------------------------- */
    /*                                   EVENTS                                   */
    /* -------------------------------------------------------------------------- */

    /// @notice The first `skim` recorded the starting watermark. Nothing moved.
    event Initialized(uint256 principal);

    /// @notice A skim completed.
    /// @param assets Position when the skim started, before any ratchet or absorption.
    /// @param yieldAmt Yield recognized by this skim (before splitting between recipients and the retained share).
    /// @param take Amount moved from the vault into this contract.
    /// @param principal Watermark after the skim.
    event Skimmed(uint256 assets, uint256 yieldAmt, uint256 take, uint256 principal);

    /// @notice A recipient was credited by a skim.
    event Credited(address indexed recipient, uint256 amount);

    /// @notice A recipient pulled its accrued balance.
    event Pulled(address indexed recipient, uint256 amount);

    /// @notice A recipient was added.
    event RecipientAdded(address indexed recipient, uint16 shareBps, uint32 minInterval);

    /// @notice A recipient's share or interval changed. Accrued balance is untouched.
    event RecipientUpdated(address indexed recipient, uint16 shareBps, uint32 minInterval);

    /// @notice A recipient was removed; `forfeited` was sent back to the account.
    event RecipientRemoved(address indexed recipient, uint256 forfeited);

    /// @notice The rate cap or the per-skim cap changed.
    event CapUpdated(uint16 capBps, uint256 absoluteMaxPerSkim);

    /// @notice The watermark was reset to the current position.
    event PrincipalReset(uint256 principal);

    /// @notice `skim` and `pull` were stopped.
    event Paused();

    /// @notice `skim` and `pull` were resumed.
    event Unpaused();

    /// @notice The module's whole asset balance was sent to `to` and every recipient's accrued balance was zeroed.
    event Drained(address indexed to, uint256 amount);

    /* -------------------------------------------------------------------------- */
    /*                                   ERRORS                                   */
    /* -------------------------------------------------------------------------- */

    /// @notice Caller is not the account.
    error NotAccount();

    /// @notice A required address was zero.
    error ZeroAddress();

    /// @notice `vault.asset()` is not the configured asset.
    error AssetMismatch(address vaultAsset, address asset);

    /// @notice `capBps` must be non-zero.
    error InvalidCap();

    /// @notice `skim` and `pull` are paused.
    error SkimmerPaused();

    /// @notice The address is already a recipient.
    error RecipientExists(address recipient);

    /// @notice The address is not a recipient.
    error NotRecipient(address recipient);

    /// @notice Recipient shares would sum to more than 10,000 bps.
    error ShareOverflow(uint256 newTotal);

    /// @notice `pull` called before the recipient's interval elapsed.
    error PullTooSoon(address recipient, uint256 availableAt);

    /// @notice The recipient has nothing accrued.
    error NothingToPull(address recipient);

    /// @notice The batch left this contract with less asset than it was credited for.
    error TransferShortfall(uint256 expected, uint256 received);

    /* -------------------------------------------------------------------------- */
    /*                                 MODIFIERS                                  */
    /* -------------------------------------------------------------------------- */

    modifier onlyAccount() {
        _checkAccount();
        _;
    }

    modifier whenNotPaused() {
        _checkNotPaused();
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                CONSTRUCTOR                                 */
    /* -------------------------------------------------------------------------- */

    /// @param account_ The endowment SmartVault. Fixed forever.
    /// @param vault_ The ERC-4626 vault the account holds shares of. Fixed forever.
    /// @param asset_ The vault's underlying asset; must equal `vault_.asset()`. Fixed forever.
    /// @param capBps_ Initial annualized rate ceiling in bps; must be non-zero.
    /// @param absoluteMaxPerSkim_ Initial per-skim yield cap, in asset units.
    constructor(address account_, IERC4626 vault_, IERC20 asset_, uint16 capBps_, uint256 absoluteMaxPerSkim_) {
        if (account_ == address(0) || address(vault_) == address(0) || address(asset_) == address(0)) {
            revert ZeroAddress();
        }
        address vaultAsset = vault_.asset();
        if (vaultAsset != address(asset_)) revert AssetMismatch(vaultAsset, address(asset_));
        if (capBps_ == 0) revert InvalidCap();

        account = account_;
        vault = vault_;
        asset = asset_;
        capBps = capBps_;
        absoluteMaxPerSkim = absoluteMaxPerSkim_;

        emit CapUpdated(capBps_, absoluteMaxPerSkim_);
    }

    /* -------------------------------------------------------------------------- */
    /*                              PERMISSIONLESS                                */
    /* -------------------------------------------------------------------------- */

    /// @notice Recognizes the yield earned since the last skim and moves the recipients' share of it out of the vault
    ///         and into this contract. The first call ever only records the starting watermark.
    /// @dev Reverts, with no partial state change, if the vault cannot serve the withdrawal (there is no try/catch by
    ///      design: the next poke retries). State is written before the external batch so a reentrant call sees the
    ///      new `lastSkim`/`principal`.
    function skim() external whenNotPaused {
        uint256 assets = position();

        if (lastSkim == 0) {
            principal = assets;
            lastSkim = block.timestamp;
            emit Initialized(assets);
            return;
        }

        (uint256 newPrincipal, uint256 yieldAmt) = _evaluate(assets, principal, block.timestamp - lastSkim);
        uint256 take = yieldAmt * totalShareBps / BPS;

        // The share that is not taken is retained: it becomes endowment capital and is never skimmable again.
        newPrincipal += yieldAmt - take;
        lastSkim = block.timestamp;
        principal = newPrincipal;

        if (take > 0) {
            _credit(yieldAmt);
            _withdrawToModule(take);

            // The vault rounds shares up on `withdraw`, so the position can land a wei under the watermark.
            uint256 remaining = position();
            if (remaining < newPrincipal) {
                newPrincipal = remaining;
                principal = remaining;
            }
        }

        emit Skimmed(assets, yieldAmt, take, newPrincipal);
    }

    /// @notice Sends `r` everything credited to it, subject to its `minInterval`. Anyone may call; only `r` receives.
    /// @param r The recipient to pay.
    function pull(address r) external whenNotPaused {
        if (!_recipientSet.contains(r)) revert NotRecipient(r);

        Recipient storage rec = recipients[r];
        uint256 availableAt = uint256(rec.lastPull) + rec.minInterval;
        if (block.timestamp < availableAt) revert PullTooSoon(r, availableAt);

        uint256 amount = rec.accrued;
        if (amount == 0) revert NothingToPull(r);

        rec.accrued = 0;
        rec.lastPull = uint64(block.timestamp);
        asset.safeTransfer(r, amount);

        emit Pulled(r, amount);
    }

    /* -------------------------------------------------------------------------- */
    /*                              ADMIN (ACCOUNT)                               */
    /* -------------------------------------------------------------------------- */

    /// @notice Adds a recipient.
    /// @dev Reverts if `r` is zero or already a recipient, or if shares would sum past 10,000 bps.
    /// @param r The recipient. A plain contract address, never a SmartVault module.
    /// @param shareBps Share of every skim's yield credited to `r`, in bps.
    /// @param minInterval Minimum seconds between `pull(r)` calls.
    function addRecipient(address r, uint16 shareBps, uint32 minInterval) external onlyAccount {
        if (r == address(0)) revert ZeroAddress();
        if (!_recipientSet.add(r)) revert RecipientExists(r);

        uint256 newTotal = totalShareBps + shareBps;
        if (newTotal > BPS) revert ShareOverflow(newTotal);

        totalShareBps = newTotal;
        recipients[r] = Recipient({ shareBps: shareBps, minInterval: minInterval, lastPull: 0, accrued: 0 });

        emit RecipientAdded(r, shareBps, minInterval);
    }

    /// @notice Changes an existing recipient's share and interval. Its accrued balance is untouched and only later
    ///         skims use the new share.
    /// @dev Reverts if `r` is not a recipient or if shares would sum past 10,000 bps.
    /// @param r The recipient.
    /// @param shareBps New share in bps.
    /// @param minInterval New minimum seconds between pulls.
    function setRecipient(address r, uint16 shareBps, uint32 minInterval) external onlyAccount {
        if (!_recipientSet.contains(r)) revert NotRecipient(r);

        Recipient storage rec = recipients[r];
        uint256 newTotal = totalShareBps - rec.shareBps + shareBps;
        if (newTotal > BPS) revert ShareOverflow(newTotal);

        totalShareBps = newTotal;
        rec.shareBps = shareBps;
        rec.minInterval = minInterval;

        emit RecipientUpdated(r, shareBps, minInterval);
    }

    /// @notice Removes a recipient and forfeits its unpulled `accrued` back to the account, where auto-earn sweeps it
    ///         into the vault and the watermark rules treat it like any other inflow.
    /// @param r The recipient to remove.
    function removeRecipient(address r) external onlyAccount {
        if (!_recipientSet.remove(r)) revert NotRecipient(r);

        Recipient memory rec = recipients[r];
        totalShareBps -= rec.shareBps;
        delete recipients[r];

        if (rec.accrued != 0) asset.safeTransfer(account, rec.accrued);

        emit RecipientRemoved(r, rec.accrued);
    }

    /// @notice Sets the annualized rate ceiling and the per-skim cap.
    /// @dev `capBps_` may be up to 65,535 but must be non-zero. `absoluteMaxPerSkim_ == 0` is allowed and makes every
    ///      skim recognize no yield (the whole excess is still absorbed or retained as usual).
    /// @param capBps_ New annualized rate ceiling in bps.
    /// @param absoluteMaxPerSkim_ New per-skim yield cap in asset units.
    function setCap(uint16 capBps_, uint256 absoluteMaxPerSkim_) external onlyAccount {
        if (capBps_ == 0) revert InvalidCap();

        capBps = capBps_;
        absoluteMaxPerSkim = absoluteMaxPerSkim_;

        emit CapUpdated(capBps_, absoluteMaxPerSkim_);
    }

    /// @notice Sets the watermark to the current position and restarts the elapsed-time clock. An escape hatch, not a
    ///         ritual. Also initializes the watermark if no skim has happened yet.
    function resetPrincipal() external onlyAccount {
        uint256 assets = position();

        principal = assets;
        lastSkim = block.timestamp;

        emit PrincipalReset(assets);
    }

    /// @notice Stops `skim` and `pull`. Admin functions keep working.
    function pause() external onlyAccount {
        paused = true;
        emit Paused();
    }

    /// @notice Resumes `skim` and `pull`.
    function unpause() external onlyAccount {
        paused = false;
        emit Unpaused();
    }

    /// @notice Sends this contract's entire asset balance to `to` and zeroes every recipient's accrued balance. Use it
    ///         before disabling the module so nothing is stranded. Works while paused.
    /// @param to Destination, normally the account.
    function drainTo(address to) external onlyAccount {
        if (to == address(0)) revert ZeroAddress();

        uint256 n = _recipientSet.length();
        for (uint256 i; i < n; ++i) {
            recipients[_recipientSet.at(i)].accrued = 0;
        }

        uint256 amount = asset.balanceOf(address(this));
        if (amount != 0) asset.safeTransfer(to, amount);

        emit Drained(to, amount);
    }

    /* -------------------------------------------------------------------------- */
    /*                                   VIEWS                                    */
    /* -------------------------------------------------------------------------- */

    /// @notice What `skim()` would recognize and move if called now. `(0, 0)` before the first skim.
    /// @return yieldAmt Yield the skim would recognize.
    /// @return take Amount the skim would move out of the vault.
    function previewSkim() external view returns (uint256 yieldAmt, uint256 take) {
        if (lastSkim == 0) return (0, 0);

        (, yieldAmt) = _evaluate(position(), principal, block.timestamp - lastSkim);
        take = yieldAmt * totalShareBps / BPS;
    }

    /// @notice The asset credited to `r` and not yet pulled.
    /// @param r The recipient.
    /// @return The accrued amount; 0 for a non-recipient.
    function accrued(address r) external view returns (uint256) {
        return recipients[r].accrued;
    }

    /// @notice Whether `r` is a recipient.
    /// @param r The address to check.
    function isRecipient(address r) external view returns (bool) {
        return _recipientSet.contains(r);
    }

    /// @notice Number of recipients.
    function recipientCount() external view returns (uint256) {
        return _recipientSet.length();
    }

    /// @notice The recipient at index `i`. Order is not stable across removals.
    /// @param i Index, must be below `recipientCount()`.
    function recipientAt(uint256 i) external view returns (address) {
        return _recipientSet.at(i);
    }

    /// @notice The account's current position in underlying-asset units. Net of all vault fees.
    /// @dev Never uses `maxWithdraw`/`maxRedeem`, which are hard-coded to 0 on Morpho V2.
    function position() public view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(account));
    }

    /* -------------------------------------------------------------------------- */
    /*                                 INTERNALS                                  */
    /* -------------------------------------------------------------------------- */

    function _checkAccount() internal view {
        if (msg.sender != account) revert NotAccount();
    }

    function _checkNotPaused() internal view {
        if (paused) revert SkimmerPaused();
    }

    /// @dev Steps 2-4 of the mechanics: ratchet, absorb, cap. Pure function of its inputs plus `capBps` and
    ///      `absoluteMaxPerSkim`, shared by `skim` and `previewSkim` so they cannot drift.
    /// @return newPrincipal The watermark after the ratchet and absorption, before the retained share is added.
    /// @return yieldAmt The yield recognized, `min(assets - newPrincipal, ceiling, absoluteMaxPerSkim)`.
    function _evaluate(
        uint256 assets,
        uint256 p,
        uint256 elapsed
    )
        internal
        view
        returns (uint256 newPrincipal, uint256 yieldAmt)
    {
        // Ratchet down: withdrawals and vault losses move the watermark with them.
        if (assets < p) p = assets;

        // `p * capBps * elapsed / (365 days * BPS)` with a 512-bit intermediate.
        uint256 ceiling = Math.mulDiv(p, uint256(capBps) * elapsed, YEAR_BPS);

        // Absorb: an excess over the ceiling cannot be yield, so it is treated as a deposit.
        uint256 excess = assets - p;
        if (excess > ceiling) {
            p = assets - ceiling;
            excess = ceiling;
        }

        newPrincipal = p;
        yieldAmt = Math.min(excess, absoluteMaxPerSkim);
    }

    /// @dev Step 8: credit each recipient its share of `yieldAmt`. Per-recipient rounding is down, so the credited sum
    ///      never exceeds `yieldAmt * totalShareBps / BPS` and the dust stays here, uncredited.
    function _credit(uint256 yieldAmt) internal {
        uint256 n = _recipientSet.length();
        for (uint256 i; i < n; ++i) {
            address r = _recipientSet.at(i);
            Recipient storage rec = recipients[r];

            uint256 amount = yieldAmt * rec.shareBps / BPS;
            if (amount != 0) {
                rec.accrued += amount;
                emit Credited(r, amount);
            }
        }
    }

    /// @dev Step 7: the only outbound calls this contract can construct. One batch, two calls: withdraw from the
    ///      vault to the account, then move the asset on to this contract in the same batch so auto-earn cannot sweep
    ///      it back into the vault. The account is `msg.sender == onBehalf` for the withdrawal, so no share allowance
    ///      is needed.
    function _withdrawToModule(uint256 take) internal {
        ISmartVaultModuleManager.Call[] memory calls = new ISmartVaultModuleManager.Call[](2);
        calls[0] = ISmartVaultModuleManager.Call({
            target: address(vault), value: 0, data: abi.encodeCall(IERC4626.withdraw, (take, account, account))
        });
        calls[1] = ISmartVaultModuleManager.Call({
            target: address(asset), value: 0, data: abi.encodeCall(IERC20.transfer, (address(this), take))
        });

        uint256 balanceBefore = asset.balanceOf(address(this));
        ISmartVaultModuleManager(account).executeFromModule(calls);
        uint256 received = asset.balanceOf(address(this)) - balanceBefore;

        // Recipients are credited out of `take`; never credit money that did not arrive.
        if (received < take) revert TransferShortfall(take, received);
    }
}
