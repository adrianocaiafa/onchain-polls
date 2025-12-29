// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title OnchainPolls
/// @notice On-chain polls: creators define questions and options, users vote once, creators close polls.
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
    event PollCreated(uint256 indexed pollId, address indexed creator, string question, uint256 optionsCount);
    event Voted(uint256 indexed pollId, address indexed voter, uint256 indexed optionIndex);
    event PollClosed(uint256 indexed pollId, address indexed creator);

    struct Poll {
        address creator;
        bool isOpen;
        string question;
        string[] options;
        uint256[] votes;
        uint256 totalVotes;
        uint256 createdAt;
        uint256 closedAt;
    }

    uint256 public pollCount;
    mapping(uint256 => Poll) private polls;

    /// @notice 1 vote per wallet per poll
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // -------------------------
    // Create
    // -------------------------
    function createPoll(string calldata question, string[] calldata options)
        external
        returns (uint256 pollId)
    {
        uint256 lenQuestion = bytes(question).length;
        if (lenQuestion == 0 || lenQuestion > MAX_LEN_QUESTION) revert InvalidQuestion();

        uint256 countOptions = options.length;
        if (countOptions < MIN_OPTIONS || countOptions > MAX_OPTIONS) revert InvalidOptions();

        for (uint256 i = 0; i < options.length; i++) {
            uint256 lenOption = bytes(options[i]).length;
            if (lenOption == 0 || lenOption > MAX_LEN_OPTION) revert InvalidOptions();
        }

        pollId = ++pollCount;

        Poll storage p = polls[pollId];
        p.creator = msg.sender;
        p.isOpen = true;
        p.question = question;
        p.createdAt = block.timestamp;

        // Copy options and initialize votes
        for (uint256 i = 0; i < options.length; i++) {
            p.options.push(options[i]);
            p.votes.push(0);
        }

        emit PollCreated(pollId, msg.sender, question, options.length);
    }

    // -------------------------
    // Vote
    // -------------------------
    function vote(uint256 pollId, uint256 optionIndex) external {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        if (!p.isOpen) revert PollIsClosed();
        if (optionIndex >= p.options.length) revert InvalidOption();
        if (hasVoted[pollId][msg.sender]) revert AlreadyVoted();

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
    // Read helpers
    // -------------------------

    /// @notice Lightweight poll info (ideal for lists/cards)
    function getPollDetails(uint256 pollId)
        external
        view
        returns (
            address creator,
            bool isOpen,
            string memory question,
            uint256 optionsCount,
            uint256 totalVotes,
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
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        return (p.options, p.votes);
    }
}
