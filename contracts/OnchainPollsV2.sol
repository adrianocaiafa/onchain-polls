// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OnchainPollsV2 {
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
    error MaxOptionsExceeded();
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
    uint256 public constant MAX_BPS = 1000; // 10%

    // Reputation thresholds
    uint256 public constant BRONZE_THRESHOLD = 100;
    uint256 public constant SILVER_THRESHOLD = 200;
    uint256 public constant GOLD_THRESHOLD = 500;
    uint256 public constant DIAMOND_THRESHOLD = 1000;

    // -------------------------
    // State
    // -------------------------
    address public builder; // Removed immutable
    address public pendingBuilder;
    uint256 public createFee;
    uint256 public builderBps;
    bool public paused;
    uint256 public defaultPollLimit;

    uint256 public pollCount;
    uint256 public builderBalance;
    address public feeToken; // Changed from IERC20 to address

    // Poll limit and whitelist
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public pollsCreatedCount;

    // Reputation and stats
    mapping(address => uint256) public totalVotesPerCreator;
    mapping(address => uint256) public reputationLevel;
    mapping(address => uint256[]) public creatorPolls;

    struct Poll {
        address creator;
        bool isOpen;
        string question;
        string[] options;
        uint256[] votes;
        uint256 totalVotes;
        uint256 feePerVote;
        uint256 createdAt;
        uint256 closedAt;
        uint256 endTime;
        address sponsor;
        uint256 sponsorFee;
        bytes32 pollHash;
    }

    mapping(uint256 => Poll) private polls;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => uint256) public creatorBalances;

    // -------------------------
    // Events
    // -------------------------
    event PollCreated(
        uint256 indexed pollId,
        address indexed creator,
        string question,
        uint256 optionsCount,
        uint256 feePerVote,
        address token,
        uint256 endTime,
        address sponsor,
        uint256 sponsorFee
    );
    event PollEdited(uint256 indexed pollId, address indexed creator);
    event Voted(uint256 indexed pollId, address indexed voter, uint256 indexed optionIndex);
    event PollClosed(uint256 indexed pollId, address indexed creator);
    event CreatorWithdraw(address indexed creator, uint256 amount, address token);
    event BuilderWithdraw(address indexed builder, uint256 amount, address token);
    event FeesUpdated(uint256 createFee, uint256 builderBps, address token);
    event PendingBuilderSet(address indexed pendingBuilder);
    event BuilderTransferred(address indexed newBuilder);
    event PausedStateChanged(bool paused);
    event PollLimitUpdated(uint256 newLimit);
    event WhitelistedAddress(address indexed account, bool isWhitelisted);
    event ReputationUpdated(address indexed creator, uint256 newLevel);
    event PollSponsored(uint256 indexed pollId, address indexed sponsor, uint256 sponsorFee);

    constructor(uint256 _createFee, uint256 _builderBps, uint256 _defaultPollLimit) {
        builder = msg.sender; // Now works since builder is not immutable
        defaultPollLimit = _defaultPollLimit;
        _setFees(_createFee, _builderBps, address(0));
    }

    // -------------------------
    // Admin Functions
    // -------------------------
    function setFees(uint256 _createFee, uint256 _builderBps, address _token) external {
        if (msg.sender != builder) revert Unauthorized();
        _setFees(_createFee, _builderBps, _token);
    }

    function _setFees(uint256 _createFee, uint256 _builderBps, address _token) internal {
        if (_createFee > MAX_CREATE_FEE) revert InvalidFee();
        if (_builderBps > MAX_BPS) revert InvalidFee();

        if (_token != address(0) && _token != feeToken) {
            require(builderBalance == 0, "Drain builderBalance first");
            require(
                feeToken == address(0) ||
                IERC20(feeToken).balanceOf(address(this)) == 0,
                "Drain token balance first"
            );
        }
        createFee = _createFee;
        builderBps = _builderBps;
        feeToken = _token;
        emit FeesUpdated(_createFee, _builderBps, _token);
    }

    function setPendingBuilder(address _newBuilder) external {
        if (msg.sender != builder) revert Unauthorized();
        pendingBuilder = _newBuilder;
        emit PendingBuilderSet(_newBuilder);
    }

    function acceptBuilder() external {
        if (msg.sender != pendingBuilder) revert Unauthorized();
        builder = msg.sender; // Now works since builder is not immutable
        emit BuilderTransferred(msg.sender);
        pendingBuilder = address(0);
    }

    function setPaused(bool _paused) external {
        if (msg.sender != builder) revert Unauthorized();
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    function setPollLimit(uint256 _newLimit) external {
        if (msg.sender != builder) revert Unauthorized();
        defaultPollLimit = _newLimit;
        emit PollLimitUpdated(_newLimit);
    }

    function setWhitelisted(address _account, bool _isWhitelisted) external {
        if (msg.sender != builder) revert Unauthorized();
        isWhitelisted[_account] = _isWhitelisted;
        emit WhitelistedAddress(_account, _isWhitelisted);
    }

    // -------------------------
    // Core Functions
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

        // Check poll limit
        if (!isWhitelisted[msg.sender] && pollsCreatedCount[msg.sender] >= defaultPollLimit) {
            revert MaxPollsReached();
        }

        // Handle payment
        if (feeToken != address(0)) {
            if (createFee != 0 && IERC20(feeToken).transferFrom(msg.sender, address(this), createFee) != true) {
                revert InvalidPayment();
            }
            if (sponsorFee != 0 && sponsor != address(0) && IERC20(feeToken).transferFrom(sponsor, address(this), sponsorFee) != true) {
                revert InvalidPayment();
            }
        } else {
            if (createFee != 0 && msg.value < createFee) revert InvalidPayment();
            if (sponsorFee != 0 && sponsor != address(0) && address(this).balance < createFee + sponsorFee) revert InvalidPayment();
            if (createFee != 0) builderBalance += createFee;
            if (sponsorFee != 0) builderBalance += sponsorFee;
        }

        // Validate inputs
        if (feePerVote > MAX_FEE_PER_VOTE) revert InvalidFee();
        if (bytes(question).length == 0 || bytes(question).length > MAX_LEN_QUESTION) revert InvalidQuestion();

        uint256 countOptions = options.length;
        if (countOptions < MIN_OPTIONS || countOptions > MAX_OPTIONS) revert InvalidOptions();

        for (uint256 i = 0; i < countOptions; i++) {
            if (bytes(options[i]).length == 0 || bytes(options[i]).length > MAX_LEN_OPTION) {
                revert InvalidOptions();
            }
        }

        // Generate poll ID
        bytes32 pollHash = keccak256(abi.encodePacked(
            msg.sender,
            block.timestamp,
            block.prevrandao,
            question
        ));
        pollId = uint256(pollHash) % (2**32 - 1);
        require(polls[pollId].creator == address(0), "Poll ID collision");

        // Create poll
        Poll storage p = polls[pollId];
        p.creator = msg.sender;
        p.isOpen = true;
        p.question = question;
        p.feePerVote = feePerVote;
        p.createdAt = block.timestamp;
        p.endTime = duration > 0 ? block.timestamp + duration : 0;
        p.sponsor = sponsor;
        p.sponsorFee = sponsorFee;
        p.pollHash = pollHash;

        for (uint256 i = 0; i < countOptions; i++) {
            p.options.push(options[i]);
            p.votes.push(0);
        }

        // Update creator stats
        pollsCreatedCount[msg.sender]++;
        creatorPolls[msg.sender].push(pollId);

        emit PollCreated(pollId, msg.sender, question, countOptions, feePerVote, feeToken, p.endTime, sponsor, sponsorFee);
        if (sponsor != address(0)) {
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

        // Clear old arrays
        for (uint256 i = 0; i < p.options.length; i++) {
            delete p.options[i];
            delete p.votes[i];
        }
        p.options = new string[](0);
        p.votes = new uint256[](0);

        // Update poll
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

        // Check if poll has ended
        if (p.endTime != 0 && block.timestamp > p.endTime) {
            p.isOpen = false;
            revert PollIsClosed();
        }

        if (optionIndex >= p.options.length) revert InvalidOption();
        if (hasVoted[pollId][msg.sender]) revert AlreadyVoted();

        // Handle payment
        uint256 fee = p.feePerVote;
        if (feeToken != address(0)) {
            if (fee != 0 && IERC20(feeToken).transferFrom(msg.sender, address(this), fee) != true) {
                revert InvalidPayment();
            }
        } else {
            if (fee != 0 && msg.value != fee) revert InvalidPayment();
            if (fee != 0) {
                uint256 cut = Math.mulDiv(fee, builderBps, 10_000);
                builderBalance += cut;
                creatorBalances[p.creator] += fee - cut;
            }
        }

        // Record vote
        hasVoted[pollId][msg.sender] = true;
        unchecked {
            p.votes[optionIndex]++;
            p.totalVotes++;
            totalVotesPerCreator[p.creator]++;
        }

        // Update reputation
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

        if (votes >= DIAMOND_THRESHOLD) {
            newLevel = 4;
        } else if (votes >= GOLD_THRESHOLD) {
            newLevel = 3;
        } else if (votes >= SILVER_THRESHOLD) {
            newLevel = 2;
        } else if (votes >= BRONZE_THRESHOLD) {
            newLevel = 1;
        } else {
            newLevel = 0;
        }

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

        if (feeToken == address(0)) {
            (bool ok, ) = msg.sender.call{value: amount}("");
            require(ok, "TRANSFER_FAILED");
        } else {
            IERC20(feeToken).transfer(msg.sender, amount);
        }
        emit CreatorWithdraw(msg.sender, amount, feeToken);
    }

    function withdrawBuilderFees() external {
        if (msg.sender != builder) revert Unauthorized();
        uint256 amount = builderBalance;
        if (amount == 0) revert NothingToWithdraw();
        builderBalance = 0;

        if (feeToken == address(0)) {
            (bool ok, ) = msg.sender.call{value: amount}("");
            require(ok, "TRANSFER_FAILED");
        } else {
            IERC20(feeToken).transfer(msg.sender, amount);
        }
        emit BuilderWithdraw(msg.sender, amount, feeToken);
    }

    // -------------------------
    // Read Functions
    // -------------------------
    function getPollDetails(uint256 pollId)
        external
        view
        returns (
            address creator,
            bool isOpen,
            string memory question,
            uint256 optionsCount,
            uint256 totalVotes,
            uint256 feePerVote,
            uint256 createdAt,
            uint256 closedAt,
            uint256 endTime,
            address sponsor,
            uint256 sponsorFee,
            address token
        )
    {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        return (
            p.creator,
            p.isOpen,
            p.question,
            p.options.length,
            p.totalVotes,
            p.feePerVote,
            p.createdAt,
            p.closedAt,
            p.endTime,
            p.sponsor,
            p.sponsorFee,
            feeToken
        );
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

    function getPollsByCreator(address creator)
        external
        view
        returns (uint256[] memory)
    {
        return creatorPolls[creator];
    }

    function getCreatorStats(address creator)
        external
        view
        returns (
            uint256 totalPolls,
            uint256 totalVotes,
            uint256 reputation,
            uint256 pendingFees
        )
    {
        return (
            pollsCreatedCount[creator],
            totalVotesPerCreator[creator],
            reputationLevel[creator],
            creatorBalances[creator]
        );
    }

    function getLeaderboard(uint256 limit)
        external
        view
        returns (address[] memory creators, uint256[] memory votes)
    {
        address[] memory topCreators = new address[](limit);
        uint256[] memory topVotes = new uint256[](limit);

        uint256 count = 0;
        for (uint256 i = 0; i < limit && count < limit; i++) {
            if (i >= pollCount) break;

            Poll storage p = polls[i];
            if (p.creator != address(0)) {
                bool found = false;
                for (uint256 j = 0; j < count; j++) {
                    if (topCreators[j] == p.creator) {
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    topCreators[count] = p.creator;
                    topVotes[count] = totalVotesPerCreator[p.creator];
                    count++;
                }
            }
        }

        // Simple bubble sort
        for (uint256 i = 0; i < count - 1; i++) {
            for (uint256 j = 0; j < count - i - 1; j++) {
                if (topVotes[j] < topVotes[j + 1]) {
                    (topCreators[j], topCreators[j + 1]) = (topCreators[j + 1], topCreators[j]);
                    (topVotes[j], topVotes[j + 1]) = (topVotes[j + 1], topVotes[j]);
                }
            }
        }

        return (topCreators, topVotes);
    }

    function isPollOpen(uint256 pollId)
        external
        view
        returns (bool)
    {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        return p.isOpen && (p.endTime == 0 || block.timestamp <= p.endTime);
    }
}