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

}
