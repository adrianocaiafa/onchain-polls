// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title OnchainPolls
/// @notice Enquetes on-chain: criador define pergunta e opções, usuários votam (1 voto/carteira), criador encerra.
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
        uint256[] votes; // votes[i] => total da opção i
        uint256 createdAt;
        uint256 closedAt;
    }

    uint256 public pollCount;
    mapping(uint256 => Poll) private polls;

    /// @notice 1 voto por carteira por enquete
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // -------------------------
    // Create
    // -------------------------
    function createPoll(string calldata question, string[] calldata options) external returns (uint256 pollId) {
        if (bytes(question).length == 0) revert InvalidQuestion();
        if (options.length < 2) revert InvalidOptions();

        // (opcional) impedir opções vazias
        for (uint256 i = 0; i < options.length; i++) {
            if (bytes(options[i]).length == 0) revert InvalidOptions();
        }

        pollId = ++pollCount;

        Poll storage p = polls[pollId];
        p.creator = msg.sender;
        p.isOpen = true;
        p.question = question;
        p.createdAt = block.timestamp;

        // Copia item a item (evita erro do old code generator)
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
    function getPollMeta(uint256 pollId)
        external
        view
        returns (
            address creator,
            bool isOpen,
            string memory question,
            uint256 optionsCount,
            uint256 createdAt,
            uint256 closedAt
        )
    {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        return (p.creator, p.isOpen, p.question, p.options.length, p.createdAt, p.closedAt);
    }

    function getOption(uint256 pollId, uint256 optionIndex)
        external
        view
        returns (string memory option, uint256 totalVotes)
    {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        if (optionIndex >= p.options.length) revert InvalidOption();
        return (p.options[optionIndex], p.votes[optionIndex]);
    }

    function getAllOptions(uint256 pollId) external view returns (string[] memory options, uint256[] memory votes) {
        Poll storage p = polls[pollId];
        if (p.creator == address(0)) revert PollNotFound();
        return (p.options, p.votes);
    }
}
