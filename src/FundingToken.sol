// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../lib/solady/src/tokens/ERC20.sol";

contract ENTToken is ERC20 {    
    string public constant NAME = "Entropy";    
    string public constant SYMBOL = "ENT";
    constructor() {        
        _mint(msg.sender, 1_000_000 * 10**uint256(18));
    }
 
    function name() public view override returns (string memory) {
        return NAME;
    }

    function symbol() public view override returns (string memory) {
        return SYMBOL;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}