// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { MockERC20 } from "./MockERC20.sol";

/// @notice Minimal ERC-4626 with 18-decimal shares over a 6-decimal asset, whose share price the test controls.
/// @dev Mirrors the Morpho V2 behavior the module cares about: `maxDeposit/maxMint/maxWithdraw/maxRedeem` return 0,
///      `convertToAssets` rounds down, `withdraw` burns shares rounded up and spends allowance only when the caller is
///      not `owner`. `pricePerShare` is in 1e18 units where 1e18 means 1 asset-wei per 1e12 share-wei (par, as at
///      deployment of a real 6-decimal-asset/18-decimal-share vault).
contract MockVault is ERC20, IERC4626 {
    using SafeERC20 for IERC20;

    uint256 internal constant SHARE_SCALE = 1e30; // 1e18 (price precision) * 1e12 (decimal gap)

    MockERC20 public token;

    uint256 public pricePerShare = 1e18;

    /// @notice When true, `withdraw` and `redeem` revert, like a vault whose liquidity adapter is dry.
    bool public withdrawReverts;

    error LiquidityShortfall();

    constructor(MockERC20 token_) ERC20("Mock Vault", "mVAULT") {
        token = token_;
    }

    /* ------------------------------ test controls ----------------------------- */

    /// @notice Sets the share price and, if the vault would be insolvent at the new price, mints the missing asset to
    ///         it so withdrawals always work unless `withdrawReverts` is set.
    function setPricePerShare(uint256 pps) external {
        pricePerShare = pps;
        uint256 owed = _toAssets(totalSupply());
        uint256 held = token.balanceOf(address(this));
        if (held < owed) token.mint(address(this), owed - held);
    }

    function setWithdrawReverts(bool reverts) external {
        withdrawReverts = reverts;
    }

    /* --------------------------------- ERC-4626 -------------------------------- */

    function decimals() public pure override(ERC20, IERC20Metadata) returns (uint8) {
        return 18;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function totalAssets() external view returns (uint256) {
        return _toAssets(totalSupply());
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return _toSharesDown(assets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _toAssets(shares);
    }

    function maxDeposit(address) external pure returns (uint256) {
        return 0;
    }

    function maxMint(address) external pure returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    function maxRedeem(address) external pure returns (uint256) {
        return 0;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return _toSharesDown(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return Math.mulDiv(shares, pricePerShare, SHARE_SCALE, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, SHARE_SCALE, pricePerShare, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return _toAssets(shares);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = _toSharesDown(assets);
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = Math.mulDiv(shares, pricePerShare, SHARE_SCALE, Math.Rounding.Ceil);
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        if (withdrawReverts) revert LiquidityShortfall();
        shares = previewWithdraw(assets);
        _exit(assets, shares, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (withdrawReverts) revert LiquidityShortfall();
        assets = _toAssets(shares);
        _exit(assets, shares, receiver, owner);
    }

    /* -------------------------------- internals -------------------------------- */

    function _exit(uint256 assets, uint256 shares, address receiver, address owner) internal {
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        IERC20(address(token)).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _toAssets(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, pricePerShare, SHARE_SCALE);
    }

    function _toSharesDown(uint256 assets) internal view returns (uint256) {
        return Math.mulDiv(assets, SHARE_SCALE, pricePerShare);
    }
}
