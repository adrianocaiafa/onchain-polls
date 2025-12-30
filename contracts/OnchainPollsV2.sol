// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OnchainPollsV3 {
    // -------------------------
    // Errors
    // -------------------------
    error PollNotFound();
    error PollIsClosed();
    error NotCreator();
    error InvalidOption();
    error AlreadyVoted();
    error InvalidQuestion();
    error InvalidOptions();
    error PollHasVotes();
    error InvalidFee();
    error InvalidPayment();
    error NothingToWithdraw();
    error Unauthorized();
    error Paused();
    error MaxPollsReached();
    error NotWhitelisted();
    error InvalidDuration();

    // -------------------------
    // Constants
    // -------------------------
    uint256 public constant MAX_LEN_QUESTION = 280;
    uint256 public constant MAX_LEN_OPTION = 84;
    uint256 public constant MIN_OPTIONS = 2;
    uint256 public constant MAX_OPTIONS = 10;

    uint256 public constant MAX_FEE_PER_VOTE = 0.001 ether;
    uint256 public constant MAX_CREATE_FEE = 0.005 ether;

    // builderBps in basis points over 10_000 (e.g. 250 = 2.5%)
    uint256 public constant MAX_BPS = 1000; // 10%
    uint256 public constant BPS_DENOM = 10_000;

    // Reputation thresholds
    uint256 public constant BRONZE_THRESHOLD = 100;
    uint256 public constant SILVER_THRESHOLD = 200;
    uint256 public constant GOLD_THRESHOLD = 500;
    uint256 public constant DIAMOND_THRESHOLD = 1000;

    // -------------------------
    // State
    // -------------------------
    address public builder;
    address public pendingBuilder;

    uint256 public createFee;     // paid at poll creation (global)
    uint256 public builderBps;    // applies ONLY to future polls (frozen per poll at creation)
    bool public paused;

    uint256 public defaultPollLimitDaily; // per day

    uint256 public pollCount;        // sequential pollId source
    uint256 public builderBalance;   // global builder fees accrued (withdrawable)

    // whitelist bypasses daily poll limit
    mapping(address => bool) public isWhitelisted;

    // Daily poll limit: creator => dayIndex => count
    mapping(address => mapping(uint256 => uint256)) public pollsCreatedPerDay;

    // Reputation and stats
    mapping(address => uint256) public totalVotesPerCreator;
    mapping(address => uint256) public reputationLevel;
    mapping(address => uint256[]) public creatorPolls;

    // per poll vote tracking
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // per creator fees accrued (withdrawable)
    mapping(address => uint256) public creatorBalances;

    struct Poll {
        address creator;
        bool isOpen;

        string question;
        string[] options;
        uint256[] votes;

        uint256 totalVotes;

        uint256 feePerVote; // ETH per vote
        uint256 createdAt;
        uint256 closedAt;
        uint256 endTime;    // 0 = no end

        // fees config frozen per poll
        uint256 builderBpsAtCreation;

        // accounting per poll
        uint256 totalVoteFeesCollected;   // total ETH collected from voters in this poll
        uint256 totalBuilderFeesCollected; // builder cut for this poll
        uint256 totalCreatorFeesCollected; // creator earnings for this poll

        // metadata
        address sponsor;
        uint256 sponsorFee;
        bytes32 pollHash;
    }

    mapping(uint256 => Poll) private polls;

    // -------------------------
    // Events
    // -------------------------
    event PollCreated(
        uint256 indexed pollId,
        address indexed creator,
        string question,
        uint256 optionsCount,
        uint256 feePerVote,
        uint256 endTime,
        address sponsor,
        uint256 sponsorFee,
        uint256 builderBpsAtCreation
    );

    event PollEdited(uint256 indexed pollId, address indexed creator);
    event Voted(uint256 indexed pollId, address indexed voter, uint256 indexed optionIndex);
    event PollClosed(uint256 indexed pollId, address indexed creator);

    event CreatorWithdraw(address indexed creator, uint256 amount);
    event BuilderWithdraw(address indexed builder, uint256 amount);

    event FeesUpdated(uint256 createFee, uint256 builderBps);
    event PendingBuilderSet(address indexed pendingBuilder);
    event BuilderTransferred(address indexed newBuilder);

    event PausedStateChanged(bool paused);
    event PollLimitUpdated(uint256 newLimitDaily);
    event WhitelistedAddress(address indexed account, bool isWhitelisted);

    event ReputationUpdated(address indexed creator, uint256 newLevel);
    event PollSponsored(uint256 indexed pollId, address indexed sponsor, uint256 sponsorFee);

    // -------------------------
    // Views
    // -------------------------
    struct PollDetails {
        uint256 pollId;

        address creator;
        bool isOpen;

        string question;
        uint256 optionsCount;
        uint256 totalVotes;

        uint256 feePerVote;
        uint256 createdAt;
        uint256 closedAt;
        uint256 endTime;

        address sponsor;
        uint256 sponsorFee;

        // frozen config
        uint256 builderBpsAtCreation;

        // accounting
        uint256 totalVoteFeesCollected;
        uint256 totalBuilderFeesCollected;
        uint256 totalCreatorFeesCollected;

        // global
        uint256 builderBalanceGlobal;
        uint256 createFeeGlobal;
    }

    constructor(uint256 _createFee, uint256 _builderBps, uint256 _defaultPollLimitDaily) {
        builder = msg.sender;
        defaultPollLimitDaily = _defaultPollLimitDaily;
        _setFees(_createFee, _builderBps);
    }

    // -------------------------
    // Admin
    // -------------------------
    function setFees(uint256 _createFee, uint256 _builderBps) external {
        if (msg.sender != builder) revert Unauthorized();
        _setFees(_createFee, _builderBps);
    }

    function _setFees(uint256 _createFee, uint256 _builderBps) internal {
        if (_createFee > MAX_CREATE_FEE) revert InvalidFee();
        if (_builderBps > MAX_BPS) revert InvalidFee();
        createFee = _createFee;
        builderBps = _builderBps;
        emit FeesUpdated(_createFee, _builderBps);
    }

    function setPendingBuilder(address _newBuilder) external {
        if (msg.sender != builder) revert Unauthorized();
        pendingBuilder = _newBuilder;
        emit PendingBuilderSet(_newBuilder);
    }

    function acceptBuilder() external {
        if (msg.sender != pendingBuilder) revert Unauthorized();
        builder = msg.sender;
        pendingBuilder = address(0);
        emit BuilderTransferred(msg.sender);
    }

    function setPaused(bool _paused) external {
        if (msg.sender != builder) revert Unauthorized();
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    function setPollLimitDaily(uint256 _newLimitDaily) external {
        if (msg.sender != builder) revert Unauthorized();
        defaultPollLimitDaily = _newLimitDaily;
        emit PollLimitUpdated(_newLimitDaily);
    }

    function setWhitelisted(address _account, bool _isWhitelisted) external {
        if (msg.sender != builder) revert Unauthorized();
        isWhitelisted[_account] = _isWhitelisted;
        emit WhitelistedAddress(_account, _isWhitelisted);
    }

    // -------------------------
    // Core
    // -------------------------
    function createPoll(
        string calldata question,
        string[] calldata options,
        uint256 feePerVote,
        uint256 duration,
        address sponsor,
        uint256 sponsorFee
    ) external payable returns (uint256 pollId) {
        if (paused) revert Paused();

        // daily limit
        if (!isWhitelisted[msg.sender]) {
            uint256 dayIndex = block.timestamp / 1 days;
            if (pollsCreatedPerDay[msg.sender][dayIndex] >= defaultPollLimitDaily) revert MaxPollsReached();
            pollsCreatedPerDay[msg.sender][dayIndex] += 1;
        }

        // validate inputs
        if (feePerVote > MAX_FEE_PER_VOTE) revert InvalidFee();
        if (bytes(question).length == 0 || bytes(question).length > MAX_LEN_QUESTION) revert InvalidQuestion();

        uint256 countOptions = options.length;
        if (countOptions < MIN_OPTIONS || countOptions > MAX_OPTIONS) revert InvalidOptions();

        for (uint256 i = 0; i < countOptions; i++) {
            if (bytes(options[i]).length == 0 || bytes(options[i]).length > MAX_LEN_OPTION) {
                revert InvalidOptions();
            }
        }

        if (duration != 0 && duration < 60) revert InvalidDuration(); // evita polls “instantâneas” (ajuste se quiser)
        if (sponsorFee != 0 && sponsor == address(0)) revert InvalidPayment();

        // payment: createFee (from msg.sender) + sponsorFee (sponsor can top-up via same tx: msg.value)
        uint256 required = createFee + sponsorFee;
        if (required != 0 && msg.value < required) revert InvalidPayment();

        if (createFee != 0) builderBalance += createFee;
        if (sponsorFee != 0) builderBalance += sponsorFee;

        // sequential pollId
        pollCount += 1;
        pollId = pollCount;

        // create poll
        Poll storage p = polls[pollId];
        p.creator = msg.sender;
        p.isOpen = true;
        p.question = question;
        p.feePerVote = feePerVote;
        p.createdAt = block.timestamp;
        p.endTime = duration > 0 ? block.timestamp + duration : 0;

        p.sponsor = sponsor;
        p.sponsorFee = sponsorFee;

        // freeze config for this poll
        p.builderBpsAtCreation = builderBps;

        // metadata hash
        p.pollHash = keccak256(abi.encodePacked(msg.sender, block.timestamp, block.prevrandao, question, pollId));

        for (uint256 i = 0; i < countOptions; i++) {
            p.options.push(options[i]);
            p.votes.push(0);
        }

        creatorPolls[msg.sender].push(pollId);

        emit PollCreated(
            pollId,
            msg.sender,
            question,
            countOptions,
            feePerVote,
            p.endTime,
            sponsor,
            sponsorFee,
            p.builderBpsAtCreation
        );

        if (sponsor != address(0) && sponsorFee != 0) {
            emit PollSponsored(pollId, sponsor, sponsorFee);
        }
    }

    function editPoll(
        uint256 pollId,
        string calldata newQuestion,
        string[] calldata newOptions,
        uint256 newDuration
    ) external {
        if (paused) revert Paused();
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        if (msg.sender != p.creator) revert NotCreator();
        if (!p.isOpen) revert PollIsClosed();
        if (p.totalVotes != 0) revert PollHasVotes();

        if (bytes(newQuestion).length == 0 || bytes(newQuestion).length > MAX_LEN_QUESTION) {
            revert InvalidQuestion();
        }

        uint256 countOptions = newOptions.length;
        if (countOptions < MIN_OPTIONS || countOptions > MAX_OPTIONS) revert InvalidOptions();

        for (uint256 i = 0; i < countOptions; i++) {
            if (bytes(newOptions[i]).length == 0 || bytes(newOptions[i]).length > MAX_LEN_OPTION) {
                revert InvalidOptions();
            }
        }

        if (newDuration != 0 && newDuration < 60) revert InvalidDuration();

        // clear arrays without looping item-by-item
        delete p.options;
        delete p.votes;

        // update poll
        p.question = newQuestion;
        p.endTime = newDuration > 0 ? block.timestamp + newDuration : 0;

        for (uint256 i = 0; i < countOptions; i++) {
            p.options.push(newOptions[i]);
            p.votes.push(0);
        }

        emit PollEdited(pollId, msg.sender);
    }

    function vote(uint256 pollId, uint256 optionIndex) external payable {
        if (paused) revert Paused();
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        if (!p.isOpen) revert PollIsClosed();

        // auto-close if time ended
        if (p.endTime != 0 && block.timestamp > p.endTime) {
            p.isOpen = false;
            p.closedAt = block.timestamp;
            revert PollIsClosed();
        }

        if (optionIndex >= p.options.length) revert InvalidOption();
        if (hasVoted[pollId][msg.sender]) revert AlreadyVoted();

        uint256 fee = p.feePerVote;
        if (fee != 0) {
            if (msg.value != fee) revert InvalidPayment();

            uint256 cut = Math.mulDiv(fee, p.builderBpsAtCreation, BPS_DENOM);
            builderBalance += cut;

            uint256 creatorCut = fee - cut;
            creatorBalances[p.creator] += creatorCut;

            p.totalVoteFeesCollected += fee;
            p.totalBuilderFeesCollected += cut;
            p.totalCreatorFeesCollected += creatorCut;
        } else {
            // no fee polls must not accept ETH
            if (msg.value != 0) revert InvalidPayment();
        }

        hasVoted[pollId][msg.sender] = true;

        unchecked {
            p.votes[optionIndex] += 1;
            p.totalVotes += 1;
            totalVotesPerCreator[p.creator] += 1;
        }

        _updateReputation(p.creator);

        emit Voted(pollId, msg.sender, optionIndex);
    }

    function closePoll(uint256 pollId) external {
        if (paused) revert Paused();
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        if (msg.sender != p.creator) revert NotCreator();
        if (!p.isOpen) revert PollIsClosed();

        p.isOpen = false;
        p.closedAt = block.timestamp;
        emit PollClosed(pollId, msg.sender);
    }

    function _updateReputation(address creator) internal {
        uint256 votes = totalVotesPerCreator[creator];
        uint256 newLevel;

        if (votes >= DIAMOND_THRESHOLD) newLevel = 4;
        else if (votes >= GOLD_THRESHOLD) newLevel = 3;
        else if (votes >= SILVER_THRESHOLD) newLevel = 2;
        else if (votes >= BRONZE_THRESHOLD) newLevel = 1;
        else newLevel = 0;

        if (newLevel != reputationLevel[creator]) {
            reputationLevel[creator] = newLevel;
            emit ReputationUpdated(creator, newLevel);
        }
    }

    // -------------------------
    // Withdrawals
    // -------------------------
    function withdrawCreatorFees() external {
        uint256 amount = creatorBalances[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        creatorBalances[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "TRANSFER_FAILED");

        emit CreatorWithdraw(msg.sender, amount);
    }

    function withdrawBuilderFees() external {
        if (msg.sender != builder) revert Unauthorized();
        uint256 amount = builderBalance;
        if (amount == 0) revert NothingToWithdraw();
        builderBalance = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "TRANSFER_FAILED");

        emit BuilderWithdraw(msg.sender, amount);
    }

    // -------------------------
    // Read Functions
    // -------------------------
    function getPollDetails(uint256 pollId) external view returns (PollDetails memory d) {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();

        d.pollId = pollId;

        d.creator = p.creator;
        d.isOpen = p.isOpen && (p.endTime == 0 || block.timestamp <= p.endTime);

        d.question = p.question;
        d.optionsCount = p.options.length;
        d.totalVotes = p.totalVotes;

        d.feePerVote = p.feePerVote;
        d.createdAt = p.createdAt;
        d.closedAt = p.closedAt;
        d.endTime = p.endTime;

        d.sponsor = p.sponsor;
        d.sponsorFee = p.sponsorFee;

        d.builderBpsAtCreation = p.builderBpsAtCreation;

        d.totalVoteFeesCollected = p.totalVoteFeesCollected;
        d.totalBuilderFeesCollected = p.totalBuilderFeesCollected;
        d.totalCreatorFeesCollected = p.totalCreatorFeesCollected;

        d.builderBalanceGlobal = builderBalance;
        d.createFeeGlobal = createFee;
    }

    function getPollOption(uint256 pollId, uint256 index)
        external
        view
        returns (string memory option, uint256 votes)
    {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        if (index >= p.options.length) revert InvalidOption();
        return (p.options[index], p.votes[index]);
    }

    function getPollResults(uint256 pollId)
        external
        view
        returns (string[] memory options, uint256[] memory votes)
    {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        return (p.options, p.votes);
    }

    function getPollsByCreator(address creator) external view returns (uint256[] memory) {
        return creatorPolls[creator];
    }

    function getCreatorStats(address creator)
        external
        view
        returns (uint256 totalPollsEver, uint256 totalVotes, uint256 reputation, uint256 pendingFees)
    {
        return (
            creatorPolls[creator].length,
            totalVotesPerCreator[creator],
            reputationLevel[creator],
            creatorBalances[creator]
        );
    }

    function getPollsCreatedToday(address creator) external view returns (uint256) {
        uint256 dayIndex = block.timestamp / 1 days;
        return pollsCreatedPerDay[creator][dayIndex];
    }

    function isPollOpen(uint256 pollId) external view returns (bool) {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        return p.isOpen && (p.endTime == 0 || block.timestamp <= p.endTime);
    }
}
