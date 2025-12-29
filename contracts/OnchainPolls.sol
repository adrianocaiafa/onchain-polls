// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title OnchainPolls
/// @notice On-chain polls: creators define questions/options, users vote once, creators close polls.
///         Optional feePerVote per poll; builder takes a small share (bps) of vote fees; createFee per poll.
contract OnchainPolls {
    // -------------------------
    // Errors (gas efficient)
    // -------------------------
    error PollNotFound();
    error PollIsClosed();
    error NotCreator();
    error InvalidOption();
    error AlreadyVoted();
    error InvalidQuestion();
    error InvalidOptions();
    error PollHasVotes();            // cannot edit after first vote
    error InvalidFee();
    error InvalidPayment();
    error NothingToWithdraw();

    // ------------------------
    // Constants (guardrails)
    // ------------------------
    uint256 public constant MAX_LEN_QUESTION = 280;
    uint256 public constant MAX_LEN_OPTION = 84;
    uint256 public constant MIN_OPTIONS = 2;
    uint256 public constant MAX_OPTIONS = 10;

    /// @dev 0.001 ETH max per vote (Base uses ETH as native)
    uint256 public constant MAX_FEE_PER_VOTE = 0.001 ether;

    /// @dev 0.005 ETH max to create a poll
    uint256 public constant MAX_CREATE_FEE = 0.005 ether;

    /// @dev builder share max 10% (1000 bps)
    uint256 public constant MAX_BPS = 1000;

    // -------------------------
    // Events
    // -------------------------
    event PollCreated(uint256 indexed pollId, address indexed creator, string question, uint256 optionsCount, uint256 feePerVote);
    event PollEdited(uint256 indexed pollId, address indexed creator);
    event Voted(uint256 indexed pollId, address indexed voter, uint256 indexed optionIndex);
    event PollClosed(uint256 indexed pollId, address indexed creator);
    event CreatorWithdraw(address indexed creator, uint256 amount);
    event BuilderWithdraw(address indexed builder, uint256 amount);
    event FeesUpdated(uint256 createFee, uint256 builderBps);

    // -------------------------
    // State
    // -------------------------
    address public immutable builder;     // you (deployer)
    uint256 public createFee;             // fee charged on createPoll
    uint256 public builderBps;            // builder cut from feePerVote (in basis points)

    uint256 public pollCount;
    uint256 public builderBalance;

    struct Poll {
        address creator;
        bool isOpen;
        string question;
        string[] options;
        uint256[] votes;
        uint256 totalVotes;
        uint256 feePerVote;   // per-poll vote fee (can be 0)
        uint256 createdAt;
        uint256 closedAt;
    }

    mapping(uint256 => Poll) private polls;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @dev accumulated fees for poll creators
    mapping(address => uint256) public creatorBalances;

    constructor(uint256 _createFee, uint256 _builderBps) {
        builder = msg.sender;
        _setFees(_createFee, _builderBps);
    }

    // -------------------------
    // Admin-like (builder only)
    // -------------------------
    function setFees(uint256 _createFee, uint256 _builderBps) external {
        if (msg.sender != builder) revert NotCreator();
        _setFees(_createFee, _builderBps);
    }

    function _setFees(uint256 _createFee, uint256 _builderBps) internal {
        if (_createFee > MAX_CREATE_FEE) revert InvalidFee();
        if (_builderBps > MAX_BPS) revert InvalidFee();
        createFee = _createFee;
        builderBps = _builderBps;
        emit FeesUpdated(_createFee, _builderBps);
    }

    // -------------------------
    // Create
    // -------------------------
    function createPoll(
        string calldata question,
        string[] calldata options,
        uint256 feePerVote
    ) external payable returns (uint256 pollId) {
        // payment: require exact createFee (and block accidental extra)
        if (createFee == 0) {
            if (msg.value != 0) revert InvalidPayment();
        } else {
            if (msg.value != createFee) revert InvalidPayment();
            builderBalance += msg.value;
        }

        // fee per vote guardrails
        if (feePerVote > MAX_FEE_PER_VOTE) revert InvalidFee();

        uint256 lenQuestion = bytes(question).length;
        if (lenQuestion == 0 || lenQuestion > MAX_LEN_QUESTION) revert InvalidQuestion();

        uint256 countOptions = options.length;
        if (countOptions < MIN_OPTIONS || countOptions > MAX_OPTIONS) revert InvalidOptions();

        for (uint256 i = 0; i < countOptions; i++) {
            uint256 lenOption = bytes(options[i]).length;
            if (lenOption == 0 || lenOption > MAX_LEN_OPTION) revert InvalidOptions();
        }

        pollId = ++pollCount;

        Poll storage p = polls[pollId];
        p.creator = msg.sender;
        p.isOpen = true;
        p.question = question;
        p.feePerVote = feePerVote;
        p.createdAt = block.timestamp;

        for (uint256 i = 0; i < countOptions; i++) {
            p.options.push(options[i]);
            p.votes.push(0);
        }

        emit PollCreated(pollId, msg.sender, question, countOptions, feePerVote);
    }

    // -------------------------
    // Edit (only before first vote)
    // -------------------------
    function editPoll(
        uint256 pollId,
        string calldata newQuestion,
        string[] calldata newOptions
    ) external {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        if (msg.sender != p.creator) revert NotCreator();
        if (!p.isOpen) revert PollIsClosed();
        if (p.totalVotes != 0) revert PollHasVotes();

        uint256 lenQuestion = bytes(newQuestion).length;
        if (lenQuestion == 0 || lenQuestion > MAX_LEN_QUESTION) revert InvalidQuestion();

        uint256 countOptions = newOptions.length;
        if (countOptions < MIN_OPTIONS || countOptions > MAX_OPTIONS) revert InvalidOptions();

        for (uint256 i = 0; i < countOptions; i++) {
            uint256 lenOption = bytes(newOptions[i]).length;
            if (lenOption == 0 || lenOption > MAX_LEN_OPTION) revert InvalidOptions();
        }

        // clear old arrays
        delete p.options;
        delete p.votes;

        p.question = newQuestion;

        for (uint256 i = 0; i < countOptions; i++) {
            p.options.push(newOptions[i]);
            p.votes.push(0);
        }

        emit PollEdited(pollId, msg.sender);
    }

    // -------------------------
    // Vote
    // -------------------------
    function vote(uint256 pollId, uint256 optionIndex) external payable {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        if (!p.isOpen) revert PollIsClosed();
        if (optionIndex >= p.options.length) revert InvalidOption();
        if (hasVoted[pollId][msg.sender]) revert AlreadyVoted();

        // payment safety
        uint256 fee = p.feePerVote;
        if (fee == 0) {
            if (msg.value != 0) revert InvalidPayment();
        } else {
            if (msg.value != fee) revert InvalidPayment();

            // split: builder cut + creator remainder
            uint256 cut = (fee * builderBps) / 10_000;
            builderBalance += cut;
            creatorBalances[p.creator] += (fee - cut);
        }

        hasVoted[pollId][msg.sender] = true;

        unchecked {
            p.votes[optionIndex] += 1;
            p.totalVotes += 1;
        }

        emit Voted(pollId, msg.sender, optionIndex);
    }

    // -------------------------
    // Close (creator only)
    // -------------------------
    function closePoll(uint256 pollId) external {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        if (msg.sender != p.creator) revert NotCreator();
        if (!p.isOpen) revert PollIsClosed();

        p.isOpen = false;
        p.closedAt = block.timestamp;

        emit PollClosed(pollId, msg.sender);
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
        if (msg.sender != builder) revert NotCreator();
        uint256 amount = builderBalance;
        if (amount == 0) revert NothingToWithdraw();
        builderBalance = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "TRANSFER_FAILED");
        emit BuilderWithdraw(msg.sender, amount);
    }

    // -------------------------
    // Read helpers
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
            uint256 closedAt
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
            p.closedAt
        );
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
}
