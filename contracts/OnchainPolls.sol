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

}
