// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract FundingEscrow is ReentrancyGuard, Ownable {
    IERC20 public immutable token;
    address public immutable creator;
    address public immutable platform;
    uint256 public immutable amount;
    address public developer;
    bool public isReleased;
    bool public isCancelled;
    uint256 public deadline;

    event FundsDeposited(address indexed from, uint256 amount);
    event FundsReleased(address indexed to, uint256 amount);
    event FundsReturned(address indexed to, uint256 amount);
    event DeveloperAssigned(address indexed developer);

    constructor(
        address _token,
        address _creator,
        address _platform,
        uint256 _amount,
        uint256 _deadline
    ) Ownable(msg.sender){
        require(_token.code.length > 0, "Invalid token address");
        token = IERC20(_token);
        creator = _creator;
        platform = _platform;
        amount = _amount;
        deadline = _deadline;
    }

    modifier onlyPlatform() {
        require(msg.sender == platform, "Only platform can call");
        _;
    }

    modifier onlyCreator() {
        require(msg.sender == creator, "Only creator can call");
        _;
    }

    function depositFunds() external onlyCreator {
        require(!isReleased && !isCancelled, "Escrow not active for deposit");
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        require(balanceAfter - balanceBefore == amount, "Incorrect deposit amount");
        emit FundsDeposited(msg.sender, amount);
    }

    function assignDeveloper(address _developer) external onlyPlatform {
        require(!isReleased && !isCancelled, "Escrow not active");
        developer = _developer;
        emit DeveloperAssigned(_developer);
    }

    function releaseFunds() external nonReentrant onlyPlatform {
        require(!isReleased && !isCancelled, "Invalid state");
        require(developer != address(0), "Developer not assigned");
        
        isReleased = true;
        token.transfer(developer, amount);
        emit FundsReleased(developer, amount);
    }

    function returnFunds() external nonReentrant {
        require(!isReleased && !isCancelled, "Invalid state");
        require(
            msg.sender == creator || 
            (msg.sender == platform && block.timestamp > deadline),
            "Unauthorized"
        );

        isCancelled = true;
        token.transfer(creator, amount);
        emit FundsReturned(creator, amount);
    }

    function getEscrowBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
            
    
    function getTokenDecimals() external view returns (uint8) {
        return IERC20Metadata(address(token)).decimals();
    }
}