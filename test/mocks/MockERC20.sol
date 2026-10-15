// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 6-decimal test token with open minting and an optional burn-on-transfer fee.
contract MockERC20 is ERC20 {
    /// @notice Fee burned from every transfer between two non-zero addresses, in bps. Test-only.
    uint256 public feeBps;

    constructor() ERC20("Mock USDC", "mUSDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeBps != 0 && from != address(0) && to != address(0)) {
            uint256 fee = value * feeBps / 10_000;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
