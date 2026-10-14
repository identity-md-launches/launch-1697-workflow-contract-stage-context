// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The fixed-supply WAKE launch token. The factory receives the entire supply.
contract LaunchToken is ERC20 {
    constructor() ERC20("A Funeral For Every Dead Token", "WAKE") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
