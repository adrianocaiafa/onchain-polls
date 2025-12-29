// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title OnchainPolls
/// @notice On-chain polls: creators define questions and options, users vote once, creators close polls.
///         Polls can be edited (question/options/fee) only BEFORE the first vote.
///         Votes may require an ETH fee per vote (can be zero).
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
    error PollAlreadyStarted(); // someone already voted
    error WrongFee();
    error WithdrawFailed();
    error NothingToWithdraw();

    // ------------------------
    // Constants
    // ------------------------
    uint256 public constant MAX_LEN_QUESTION = 280;
    uint256 public constant MAX_LEN_OPTION = 84;
    uint256 public constant MIN_OPTIONS = 2;
    uint256 public constant MAX_OPTIONS = 10;

    // -------------------------
    // Events
    // -------------------------
    event PollCreated(
        uint256 indexed pollId,
        address indexed creator,
        string question,
        uint256 optionsCount,
        uint256 feePerVoteWei
    );
    event Voted(uint256 indexed pollId, address indexed voter, uint256 indexed optionIndex, uint256 feePaidWei);
    event PollClosed(uint256 indexed pollId, address indexed creator);
    event PollQuestionEdited(uint256 indexed pollId, address indexed creator, string newQuestion);
    event PollOptionsEdited(uint256 indexed pollId, address indexed creator, uint256 newOptionsCount);
    event PollFeeEdited(uint256 indexed pollId, address indexed creator, uint256 newFeePerVoteWei);
    event FeesWithdrawn(uint256 indexed pollId, address indexed creator, uint256 amountWei);

    struct Poll {
        address creator;
        bool isOpen;

        string question;
        string[] options;

        uint256[] votes;   // votes[i] => total votes for option i
        uint256 totalVotes;

        uint256 feePerVoteWei; // can be 0
        uint256 feesAccruedWei; // accumulated from votes

        uint256 createdAt;
        uint256 closedAt;
    }

    uint256 public pollCount;
    mapping(uint256 => Poll) private polls;

    /// @notice 1 vote per wallet per poll
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // -------------------------
    // Internal validators
    // -------------------------
    function _validateQuestion(string calldata question) internal pure {
        uint256 lenQuestion = bytes(question).length;
        if (lenQuestion == 0 || lenQuestion > MAX_LEN_QUESTION) revert InvalidQuestion();
    }

    function _validateOptions(string[] calldata options) internal pure {
        uint256 countOptions = options.length;
        if (countOptions < MIN_OPTIONS || countOptions > MAX_OPTIONS) revert InvalidOptions();

        for (uint256 i = 0; i < options.length; i++) {
            uint256 lenOption = bytes(options[i]).length;
            if (lenOption == 0 || lenOption > MAX_LEN_OPTION) revert InvalidOptions();
        }
    }

    function _getPoll(uint256 pollId) internal view returns (Poll storage p) {
        p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
    }

    function _onlyCreator(Poll storage p) internal view {
        if (msg.sender != p.creator) revert NotCreator();
    }

    function _onlyBeforeFirstVote(Poll storage p) internal view {
        if (p.totalVotes != 0) revert PollAlreadyStarted();
    }

    // -------------------------
    // Create
    // -------------------------
    function createPoll(
        string calldata question,
        string[] calldata options,
        uint256 feePerVoteWei
    ) external returns (uint256 pollId) {
        _validateQuestion(question);
        _validateOptions(options);

        pollId = ++pollCount;

        Poll storage p = polls[pollId];
        p.creator = msg.sender;
        p.isOpen = true;
        p.question = question;
        p.createdAt = block.timestamp;
        p.feePerVoteWei = feePerVoteWei;

        // Copy options and initialize votes
        for (uint256 i = 0; i < options.length; i++) {
            p.options.push(options[i]);
            p.votes.push(0);
        }

        emit PollCreated(pollId, msg.sender, question, options.length, feePerVoteWei);
    }

    // -------------------------
    // Edit (only before first vote)
    // -------------------------
    function editQuestion(uint256 pollId, string calldata newQuestion) external {
        Poll storage p = _getPoll(pollId);
        _onlyCreator(p);
        if (!p.isOpen) revert PollIsClosed();
        _onlyBeforeFirstVote(p);

        _validateQuestion(newQuestion);
        p.question = newQuestion;

        emit PollQuestionEdited(pollId, msg.sender, newQuestion);
    }

    function editOptions(uint256 pollId, string[] calldata newOptions) external {
        Poll storage p = _getPoll(pollId);
        _onlyCreator(p);
        if (!p.isOpen) revert PollIsClosed();
        _onlyBeforeFirstVote(p);

        _validateOptions(newOptions);

        // Replace options and reset votes (still no votes happened, so safe)
        delete p.options;
        delete p.votes;

        for (uint256 i = 0; i < newOptions.length; i++) {
            p.options.push(newOptions[i]);
            p.votes.push(0);
        }

        emit PollOptionsEdited(pollId, msg.sender, newOptions.length);
    }

    function setVoteFee(uint256 pollId, uint256 newFeePerVoteWei) external {
        Poll storage p = _getPoll(pollId);
        _onlyCreator(p);
        if (!p.isOpen) revert PollIsClosed();
        _onlyBeforeFirstVote(p);

        p.feePerVoteWei = newFeePerVoteWei;
        emit PollFeeEdited(pollId, msg.sender, newFeePerVoteWei);
    }

    // -------------------------
    // Vote (payable)
    // -------------------------
    function vote(uint256 pollId, uint256 optionIndex) external payable {
        Poll storage p = _getPoll(pollId);
        if (!p.isOpen) revert PollIsClosed();
        if (optionIndex >= p.options.length) revert InvalidOption();
        if (hasVoted[pollId][msg.sender]) revert AlreadyVoted();

        uint256 fee = p.feePerVoteWei;
        if (msg.value != fee) revert WrongFee();

        hasVoted[pollId][msg.sender] = true;

        unchecked {
            p.votes[optionIndex] += 1;
            p.totalVotes += 1;
        }

        if (fee != 0) {
            unchecked {
                p.feesAccruedWei += fee;
            }
        }

        emit Voted(pollId, msg.sender, optionIndex, fee);
    }

    // -------------------------
    // Close (creator only)
    // -------------------------
    function closePoll(uint256 pollId) external {
        Poll storage p = _getPoll(pollId);
        _onlyCreator(p);
        if (!p.isOpen) revert PollIsClosed();

        p.isOpen = false;
        p.closedAt = block.timestamp;

        emit PollClosed(pollId, msg.sender);
    }

    // -------------------------
    // Withdraw fees (creator only)
    // -------------------------
    function withdrawFees(uint256 pollId, address payable to) external {
        Poll storage p = _getPoll(pollId);
        _onlyCreator(p);

        uint256 amount = p.feesAccruedWei;
        if (amount == 0) revert NothingToWithdraw();

        // effects first
        p.feesAccruedWei = 0;

        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();

        emit FeesWithdrawn(pollId, msg.sender, amount);
    }

    // -------------------------
    // Read helpers
    // -------------------------

    /// @notice Poll info (ideal for UI cards / details)
    function getPollDetails(uint256 pollId)
        external
        view
        returns (
            address creator,
            bool isOpen,
            string memory question,
            uint256 optionsCount,
            uint256 totalVotes,
            uint256 feePerVoteWei,
            uint256 feesAccruedWei,
            uint256 createdAt,
            uint256 closedAt
        )
    {
        Poll storage p = _getPoll(pollId);

        return (
            p.creator,
            p.isOpen,
            p.question,
            p.options.length,
            p.totalVotes,
            p.feePerVoteWei,
            p.feesAccruedWei,
            p.createdAt,
            p.closedAt
        );
    }

    /// @notice Full poll results (options + votes)
    function getPollResults(uint256 pollId)
        external
        view
        returns (string[] memory options, uint256[] memory votes)
    {
        Poll storage p = _getPoll(pollId);
        return (p.options, p.votes);
    }
}
