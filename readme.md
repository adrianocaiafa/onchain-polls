
# OnchainPollsV3 (ETH-only)

On-chain polls with optional **fee-per-vote** in ETH, **daily creation limit**, **whitelist bypass**, **frozen builder fee per poll**, and simple **reputation tiers** based on total votes received by a creator.

Designed to run on **Base (L2)**, but fully EVM-compatible.

---

## Features

- ETH-only (no ERC20)
- Sequential `pollId`
- Fee configuration locked per poll
- Daily poll creation limit (UTC)
- Optional sponsor metadata
- Builder revenue + creator revenue split
- Reputation system based on total votes
- Fully on-chain accounting

---

## Constructor

```solidity
constructor(
  uint256 _createFee,
  uint256 _builderBps,
  uint256 _defaultPollLimitDaily
)
```

### Example values

| Parameter | Example | Notes |
|---------|--------|------|
| `_createFee` | `100000000000000` | 0.0001 ETH |
| `_builderBps` | `250` | 2.5% |
| `_defaultPollLimitDaily` | `3` | polls/day |

---

## Fees

### Create Fee
- Paid once at `createPoll`
- Goes entirely to builder

### Vote Fee
- Defined per poll (`feePerVote`)
- Split:
  - Builder: `fee * builderBpsAtCreation / 10_000`
  - Creator: remainder

### Fee Locking
Each poll stores:
- `feePerVote`
- `builderBpsAtCreation`

Future fee changes only affect new polls.

---

## Daily Poll Limit

- Non-whitelisted creators can create up to `defaultPollLimitDaily` polls per UTC day
- Computed using:
```solidity
block.timestamp / 1 days
```
- Whitelisted addresses bypass the limit

---

## Sponsor

- Optional metadata field
- If `sponsorFee > 0`, `sponsor != address(0)`
- Paid by creator via `msg.value`
- Entire sponsor fee goes to builder

Null sponsor:
```
0x0000000000000000000000000000000000000000
```

---

## Core Functions

### createPoll
```solidity
createPoll(
  string question,
  string[] options,
  uint256 feePerVote,
  uint256 duration,
  address sponsor,
  uint256 sponsorFee
)
```

### vote
```solidity
vote(uint256 pollId, uint256 optionIndex)
```

### editPoll
- Only creator
- Only if poll has zero votes

### closePoll
- Only creator
- Can be closed anytime

---

## Withdrawals

### Creator
```solidity
withdrawCreatorFees()
```

### Builder
```solidity
withdrawBuilderFees()
```

---

## View Functions

- `getPollDetails`
- `getPollResults`
- `getPollOption`
- `getPollsByCreator`
- `getCreatorStats`
- `getPollsCreatedToday`
- `isPollOpen`

---

## Reputation Levels

| Level | Votes |
|------|------|
| 0 | < 100 |
| 1 (Bronze) | ≥ 100 |
| 2 (Silver) | ≥ 200 |
| 3 (Gold) | ≥ 500 |
| 4 (Diamond) | ≥ 1000 |

---

## ETH → Wei Reference

| ETH | Wei |
|----|----|
| 0.00003 | 30000000000000 |
| 0.0001 | 100000000000000 |

---

## License
MIT
