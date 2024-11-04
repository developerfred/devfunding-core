// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./FundingEscrow.sol";

contract DevFunding is ReentrancyGuard, Ownable {
    // Platform fee percentages (in basis points, 1% = 100)
    uint256 public platformFeeBps = 250; // 2.5% default platform fee
    uint256 public referralFeeBps = 100; // 1% referral bonus

    // Token for platform governance and rewards
    IERC20 public platformToken;

    // Referral tracking
    mapping(address => address) public referredBy;
    mapping(address => uint256) public referralEarnings;
    mapping(address => uint256) public referralCount;

    // Premium features tracking
    mapping(address => bool) public isPremiumUser;
    mapping(address => uint256) public premiumExpiryTime;
    uint256 public premiumPrice = 100 * 10 ** 18; // 100 tokens for premium

    // dispute
    mapping(uint256 => Dispute) public disputes;

    struct Activity {
        uint256 timestamp;
        string description;
    }

    struct Grant {
        address creator;
        uint256 amount;
        string description;
        string requirements;
        uint256 deadline;
        bool isActive;
        uint256 applicantsCount;
        mapping(address => bool) hasApplied;
        address selectedDev;
        bool isClaimed;
        address referrer;
        address escrowContract;
    }

    struct Bounty {
        address creator;
        uint256 amount;
        string issueLink;
        uint256 deadline;
        bool isActive;
        address[] contributors;
        mapping(address => uint256) contributions;
        mapping(address => bool) hasContributed;
        address referrer;
    }

    struct DevProfile {
        string githubHandle;
        string[] skills;
        uint256 completedGrants;
        uint256 reputation;
        bool isVerified;
        string portfolioUrl;
        bool isPremium;
        Activity[] activities;
    }

    struct Dispute {
        bool isDispute;
        bool isDisputeResolved;
        string resolutionOutcome;
        uint256 startTime;
        mapping(address => bool) hasVoted;
        address[] disputeBoard;
        mapping(address => bool) isBoardMember;
        uint256 yesVotes;
        uint256 noVotes;
    }

    struct DisputeBoard {
        address[] members;
        mapping(uint256 => bool) isDisputeResolved;
        mapping(uint256 => string) resolutionOutcome;
    }

    // Original mappings
    mapping(uint256 => Grant) public grants;
    mapping(uint256 => Bounty) public bounties;
    mapping(address => DevProfile) public developers;
    mapping(address => uint256[]) public devGrants;
    mapping(address => uint256[]) public devBounties;
    mapping(uint256 => string[]) public messages;
    mapping(uint256 => string) public proposals;
    mapping(uint256 => uint256) public votes;

    uint256 public proposalCount;
    uint256 public grantCount;
    uint256 public bountyCount;

    // New events
    event PremiumPurchased(address indexed user, uint256 indexed duration);
    event ReferralPaid(
        address indexed referrer,
        address indexed referred,
        uint256 indexed amount
    );
    event PlatformFeeCollected(uint256 indexed amount);
    event GrantCreated(
        uint256 indexed grantId,
        address indexed creator,
        uint256 amount
    );
    event DevProfileCreated(address indexed developer, string githubHandle);
    event GrantClaimed(uint256 indexed grantId, address indexed developer);
    event DisputeRaised(uint256 indexed id, address indexed raisedBy);
    event DisputeResolved(uint256 indexed id, string indexed outcome);
    event Voted(uint256 indexed id, address indexed voter, bool indexed vote);
    event BountyContribution(
        uint256 indexed bountyId,
        address indexed contributor,
        uint256 indexed amount
    );
    event BountyCreated(
        uint256 indexed bountyId,
        address indexed creator,
        uint256 amount,
        string  issueLink,
        uint256 indexed deadline,
        address referrer
    );

    constructor(address _platformToken) Ownable(msg.sender) {
        platformToken = IERC20(_platformToken);
    }

    function createBounty(
        uint256 amount,
        string memory issueLink,
        uint256 durationDays,
        address referrer
    ) public nonReentrant returns (uint256) {
        require(amount > 0, "Amount must be greater than 0");
        require(bytes(issueLink).length > 0, "Empty issue link");
        require(durationDays > 0 && durationDays <= 365, "Invalid duration");
        require(
            amount <= platformToken.balanceOf(msg.sender),
            "Insufficient balance"
        );

        uint256 platformFee = (amount * platformFeeBps) / 10000;
        uint256 referralFee = 0;

        if (referrer != address(0) && referrer != msg.sender) {
            referralFee = (amount * referralFeeBps) / 10000;
            referralEarnings[referrer] += referralFee;
            referralCount[referrer]++;
            emit ReferralPaid(referrer, msg.sender, referralFee);
        }

        uint256 netAmount = amount - platformFee - referralFee;

        // Transferência das taxas
        require(
            platformToken.transferFrom(
                msg.sender,
                address(this),
                platformFee + referralFee
            ),
            "Fee transfer failed"
        );

        uint256 deadline = block.timestamp + (durationDays * 1 days);
        FundingEscrow escrow = new FundingEscrow(
            address(platformToken),
            msg.sender,
            address(this),
            netAmount,
            deadline
        );

        require(
            platformToken.transferFrom(msg.sender, address(escrow), netAmount),
            "Escrow transfer failed"
        );

        Bounty storage bounty = bounties[bountyCount];
        bounty.creator = msg.sender;
        bounty.amount = netAmount;
        bounty.issueLink = issueLink;
        bounty.deadline = deadline;
        bounty.isActive = true;
        bounty.referrer = referrer;

        // Adicionar à lista de bounties do criador
        devBounties[msg.sender].push(bountyCount);

        // Emitir eventos
        emit BountyCreated(
            bountyCount,
            msg.sender,
            netAmount,
            issueLink,
            deadline,
            referrer
        );
        emit PlatformFeeCollected(platformFee);

        bountyCount++;

        return bountyCount - 1;
    }

    function createHighlightedBounty(
        uint256 amount,
        string memory issueLink,
        uint256 durationDays,
        address referrer
    ) external nonReentrant onlyPremium returns (uint256) {
        require(isPremiumUser[msg.sender], "Premium required");
        return createBounty(amount, issueLink, durationDays, referrer);
    }

    function createGrant(
        uint256 amount,
        string memory description,
        string memory requirements,
        uint256 durationDays,
        address referrer
    ) public nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(durationDays > 0, "Duration must be greater than 0");
        require(bytes(description).length > 0, "Empty description");
        require(bytes(requirements).length > 0, "Empty requirements");
        require(referrer != address(0), "Invalid referrer");

        // Calculate and deduct platform fee
        uint256 platformFee = (amount * platformFeeBps) / 10000;
        uint256 referralFee = 0;

        if (referrer != address(0) && referrer != msg.sender) {
            referralFee = (amount * referralFeeBps) / 10000;
            referralEarnings[referrer] += referralFee;
            referralCount[referrer]++;
            emit ReferralPaid(referrer, msg.sender, referralFee);
        }

        uint256 netAmount = amount - platformFee - referralFee;

        require(
            platformToken.transferFrom(
                msg.sender,
                address(this),
                platformFee + referralFee
            ),
            "Fee transfer failed"
        );

        // Create escrow contract
        uint256 deadline = block.timestamp + (durationDays * 1 days);
        FundingEscrow escrow = new FundingEscrow(
            address(platformToken),
            msg.sender,
            address(this),
            netAmount,
            deadline
        );

        // Transfer funds to escrow
        require(
            platformToken.transferFrom(msg.sender, address(escrow), netAmount),
            "Escrow transfer failed"
        );

        Grant storage grant = grants[grantCount];
        grant.creator = msg.sender;
        grant.amount = netAmount;
        grant.description = description;
        grant.requirements = requirements;
        grant.deadline = block.timestamp + (durationDays * 1 days);
        grant.isActive = true;
        grant.referrer = referrer;

        grant.escrowContract = address(escrow);

        emit GrantCreated(grantCount, msg.sender, netAmount);
        emit PlatformFeeCollected(platformFee);

        grantCount++;
    }

    function createHighlightedGrant(
        uint256 amount,
        string memory description,
        string memory requirements,
        uint256 durationDays,
        address referrer
    ) external nonReentrant onlyPremium {
        require(isPremiumUser[msg.sender], "Premium required");
        createGrant(amount, description, requirements, durationDays, referrer);
    }

    function createDevProfile(
        string memory githubHandle,
        string[] memory skills,
        string memory portfolioUrl
    ) external {
        require(
            bytes(developers[msg.sender].githubHandle).length == 0,
            "Profile already exists"
        );

        // Criando um array vazio para activities
        Activity[] memory emptyActivities = new Activity[](0);

        developers[msg.sender] = DevProfile({
            githubHandle: githubHandle,
            skills: skills,
            completedGrants: 0,
            reputation: 0,
            isVerified: false,
            portfolioUrl: portfolioUrl,
            isPremium: isPremiumUser[msg.sender],
            activities: emptyActivities
        });

        // Reward early adopters with platform tokens
        if (developers[msg.sender].reputation == 0) {
            uint256 rewardAmount = 10 * 10 ** 18; // 10 tokens
            require(
                platformToken.transfer(msg.sender, rewardAmount),
                "Transfer failed"
            );
        }

        emit DevProfileCreated(msg.sender, githubHandle);
    }

    modifier onlyPremium() {
        checkAndUpdatePremiumStatus(msg.sender);
        require(isPremiumUser[msg.sender], "Premium required");
        _;
    }

    // Função para contribuir com um bounty existente
    function contributeToBounty(
        uint256 bountyId,
        uint256 amount
    ) external nonReentrant {
        require(bounties[bountyId].isActive, "Bounty not active");
        require(amount > 0, "Amount must be greater than 0");
        require(
            block.timestamp <= bounties[bountyId].deadline,
            "Bounty expired"
        );

        // Calcular taxas para a contribuição
        uint256 platformFee = (amount * platformFeeBps) / 10000;
        uint256 netAmount = amount - platformFee;

        // Transferir taxa da plataforma
        require(
            platformToken.transferFrom(msg.sender, address(this), platformFee),
            "Fee transfer failed"
        );

        // Transferir contribuição para o escrow
        require(
            platformToken.transferFrom(msg.sender, address(this), netAmount),
            "Contribution transfer failed"
        );

        // Atualizar contribuições
        if (!bounties[bountyId].hasContributed[msg.sender]) {
            bounties[bountyId].contributors.push(msg.sender);
            bounties[bountyId].hasContributed[msg.sender] = true;
        }

        bounties[bountyId].contributions[msg.sender] += netAmount;

        emit BountyContribution(bountyId, msg.sender, netAmount);
    }

    function createDisputeBoard(
        uint256 _id,
        address[] memory _members
    ) public onlyOwner {
        require(_id < grantCount || _id < bountyCount, "Invalid ID");
        require(_members.length > 0, "Must have at least one member");
        Dispute storage dispute = disputes[_id];
        for (uint i = 0; i < _members.length; i++) {
            if (!dispute.isBoardMember[_members[i]]) {
                dispute.disputeBoard.push(_members[i]);
                dispute.isBoardMember[_members[i]] = true;
            }
        }
    }

    function raiseDispute(uint256 _id) public {
        require(_id < grantCount || _id < bountyCount, "Invalid ID");
        Dispute storage dispute = disputes[_id];
        require(
            msg.sender == grants[_id].creator ||
                msg.sender == grants[_id].selectedDev ||
                bounties[_id].contributions[msg.sender] > 0,
            "Only involved parties can raise a dispute"
        );
        require(
            !dispute.isDispute,
            "Dispute already raised for this grant/bounty"
        );
        dispute.isDispute = true;
        dispute.startTime = block.timestamp;
        emit DisputeRaised(_id, msg.sender);
    }

    function resolveDispute(uint256 _id, string memory _outcome) private {
        Dispute storage dispute = disputes[_id];
        require(dispute.isDispute, "No active dispute for this ID");
        require(!dispute.isDisputeResolved, "Dispute already resolved");
        require(
            block.timestamp <= disputes[_id].startTime + 7 days,
            "Voting period expired"
        );

        uint256 totalVotes = disputes[_id].yesVotes + disputes[_id].noVotes;
        require(
            totalVotes >= disputes[_id].disputeBoard.length / 2,
            "Quorum not reached"
        );

        dispute.resolutionOutcome = _outcome;
        dispute.isDisputeResolved = true;
        emit DisputeResolved(_id, _outcome);

        // Ação baseada no resultado da votação
        if (keccak256(bytes(_outcome)) == keccak256(bytes("Release funds"))) {
            FundingEscrow(grants[_id].escrowContract).releaseFunds();
        } else if (
            keccak256(bytes(_outcome)) == keccak256(bytes("Return funds"))
        ) {
            FundingEscrow(grants[_id].escrowContract).returnFunds();
        } else {
            revert("Unexpected resolution outcome");
        }
    }

    function voteOnDispute(uint256 _id, bool _vote) public {
        Dispute storage dispute = disputes[_id];
        require(dispute.isDispute, "No active dispute for this ID");
        require(
            dispute.isBoardMember[msg.sender],
            "Only Dispute Board members can vote"
        );
        require(!dispute.hasVoted[msg.sender], "Already voted");
        require(block.timestamp >= dispute.startTime, "Voting not started");

        dispute.hasVoted[msg.sender] = true;
        if (_vote) {
            dispute.yesVotes++;
        } else {
            dispute.noVotes++;
        }
        emit Voted(_id, msg.sender, _vote);

        // Check if we have enough votes to decide
        if (
            dispute.yesVotes > dispute.disputeBoard.length / 2 ||
            dispute.noVotes > dispute.disputeBoard.length / 2
        ) {
            resolveDispute(
                _id,
                dispute.yesVotes > dispute.noVotes
                    ? "Release funds"
                    : "Return funds"
            );
        }
    }

    function renewPremium(uint256 additionalMonths) external {
        require(isPremiumUser[msg.sender], "Not a premium user");
        require(additionalMonths > 0, "Invalid duration");

        uint256 cost = premiumPrice * additionalMonths;
        require(
            platformToken.transferFrom(msg.sender, address(this), cost),
            "Transfer failed"
        );

        premiumExpiryTime[msg.sender] += (additionalMonths * 30 days);
    }

    function checkAndUpdatePremiumStatus(address user) public {
        if (block.timestamp >= premiumExpiryTime[user]) {
            isPremiumUser[user] = false;
            if (bytes(developers[user].githubHandle).length > 0) {
                developers[user].isPremium = false;
            }
        }
    }

    function applyForGrant(uint256 grantId) external {
        Grant storage grant = grants[grantId];
        require(grant.isActive, "Grant not active");
        require(!grant.hasApplied[msg.sender], "Already applied");
        require(block.timestamp <= grant.deadline, "Grant expired");

        grant.hasApplied[msg.sender] = true;
        grant.applicantsCount++;
    }

    function containsAddress(
        address[] storage _array,
        address _address
    ) private view returns (bool) {
        for (uint i = 0; i < _array.length; i++) {
            if (_array[i] == _address) {
                return true;
            }
        }
        return false;
    }

    function cancelGrant(uint256 grantId) external {
        require(
            grants[grantId].creator == msg.sender,
            "Only creator can cancel"
        );
        require(grants[grantId].isActive, "Grant is not active");

        grants[grantId].isActive = false;
        FundingEscrow(grants[grantId].escrowContract).returnFunds();
    }

    function transferGrant(uint256 grantId, address newCreator) external {
        require(
            grants[grantId].creator == msg.sender,
            "Only creator can transfer"
        );
        require(grants[grantId].isActive, "Grant is not active");
        grants[grantId].creator = newCreator;
    }

    // Premium features
    function purchasePremium(uint256 durationMonths) external {
        require(durationMonths > 0, "Invalid duration");
        uint256 cost = premiumPrice * durationMonths;
        require(
            platformToken.transferFrom(msg.sender, address(this), cost),
            "Transfer failed"
        );

        isPremiumUser[msg.sender] = true;
        premiumExpiryTime[msg.sender] =
            block.timestamp +
            (durationMonths * 30 days);

        // Give premium status in profile
        if (bytes(developers[msg.sender].githubHandle).length > 0) {
            developers[msg.sender].isPremium = true;
        }

        emit PremiumPurchased(msg.sender, durationMonths);
    }

    function recordDeveloperActivity(
        address developer,
        string memory activityDescription
    ) external {
        developers[developer].activities.push(
            Activity(block.timestamp, activityDescription)
        );
    }

    function proposeImprovement(string memory proposal) external {
        proposals[proposalCount] = proposal;
        proposalCount++;
    }

    function voteForProposal(uint256 proposalId) external {
        votes[proposalId]++;
    }

    function registerReferral(address referrer) external {
        require(referredBy[msg.sender] == address(0), "Referrer already set");
        require(referrer != msg.sender, "Cannot refer yourself");
        referredBy[msg.sender] = referrer;
        referralCount[referrer]++;
    }

    function withdrawReferralEarnings() external {
        uint256 earnings = referralEarnings[msg.sender];
        require(earnings > 0, "No earnings to withdraw");
        referralEarnings[msg.sender] = 0;
        platformToken.transfer(msg.sender, earnings);
    }

    function _removeContributor(
        uint256 bountyId,
        address contributor
    ) internal {
        Bounty storage bounty = bounties[bountyId];
        for (uint256 i = 0; i < bounty.contributors.length; i++) {
            if (bounty.contributors[i] == contributor) {
                bounty.contributors[i] = bounty.contributors[
                    bounty.contributors.length - 1
                ];
                bounty.contributors.pop();
                break;
            }
        }
    }

    function selectDeveloper(uint256 grantId, address developer) external {
        Grant storage grant = grants[grantId];
        require(msg.sender == grant.creator, "Only creator can select");
        require(grant.isActive, "Grant not active");
        require(!grant.isClaimed, "Grant already claimed");
        require(grant.hasApplied[developer], "Developer hasn't applied");

        grant.selectedDev = developer;
        FundingEscrow(grant.escrowContract).assignDeveloper(developer);
    }

    function claimGrant(uint256 grantId) external nonReentrant {
        Grant storage grant = grants[grantId];
        require(grant.isActive, "Grant is not active");
        require(
            grant.selectedDev == msg.sender,
            "You are not the selected developer"
        );
        require(!grant.isClaimed, "Grant already claimed");
        require(block.timestamp <= grants[grantId].deadline, "Grant expired");
        require(!disputes[grantId].isDispute, "Grant in dispute");

        grant.isActive = false;
        grant.isClaimed = true;
        FundingEscrow(grant.escrowContract).releaseFunds();

        developers[msg.sender].completedGrants++;
        developers[msg.sender].reputation += grant.amount / 1e18;

        emit GrantClaimed(grantId, msg.sender);
    }

    function manageBountyContribution(
        uint256 bountyId,
        uint256 amount,
        bool isAdding
    ) external {
        Bounty storage bounty = bounties[bountyId];
        require(bounty.isActive, "Bounty is not active");

        if (isAdding) {
            require(!bounty.hasContributed[msg.sender], "Already contributed");
            bounty.contributions[msg.sender] = amount;
            bounty.contributors.push(msg.sender);
            bounty.hasContributed[msg.sender] = true;
        } else {
            require(
                bounty.contributions[msg.sender] >= amount,
                "Cannot reduce contribution below zero"
            );
            bounty.contributions[msg.sender] -= amount;
            if (bounty.contributions[msg.sender] == 0) {
                _removeContributor(bountyId, msg.sender);
                bounty.hasContributed[msg.sender] = false;
            }
        }
    }

    function updateDevProfile(
        string memory githubHandle,
        string[] memory skills,
        string memory portfolioUrl
    ) external {
        require(
            bytes(developers[msg.sender].githubHandle).length > 0,
            "Profile does not exist"
        );

        developers[msg.sender].githubHandle = githubHandle;
        developers[msg.sender].skills = skills;
        developers[msg.sender].portfolioUrl = portfolioUrl;
    }

    function sendMessage(
        uint256 grantOrBountyId,
        string memory message
    ) external {
        messages[grantOrBountyId].push(message);
    }

    // Admin functions

    function withdrawPlatformFees() external onlyOwner {
        uint256 balance = platformToken.balanceOf(address(this));
        require(balance > 0, "No fees to withdraw");
        platformToken.transfer(msg.sender, balance);
    }

    function updatePremiumPrice(uint256 newPrice) external onlyOwner {
        require(newPrice > 0, "Price must be greater than zero");
        premiumPrice = newPrice;
    }

    function updatePlatformFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 1000, "Fee too high");
        platformFeeBps = newFeeBps;
    }

    function verifyDeveloper(address devAddress) external onlyOwner {
        developers[devAddress].isVerified = true;
    }

    // View Functions
    function checkPremiumStatus(
        address user
    ) external view returns (bool, uint256) {
        return (isPremiumUser[user], premiumExpiryTime[user]);
    }

    function hasAppliedForGrant(
        uint256 grantId,
        address applicant
    ) external view returns (bool) {
        return grants[grantId].hasApplied[applicant];
    }
}
