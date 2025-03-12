# StableSwap Protocol

A decentralized stable swap protocol built on the Stacks blockchain that generates rewards for sBTC holders.

## Overview

StableSwap is a decentralized exchange protocol designed specifically for trading pairs of stablecoins or other assets with similar values. The protocol employs a specialized curve algorithm that maintains price stability while providing efficient trading between assets.

### Key Features

- **Stable Asset Trading**: Optimized for trading assets with similar values, minimizing slippage
- **Amplification Parameter**: Customizable amplification factor to balance between efficiency and stability
- **Liquidity Mining**: LP token rewards for liquidity providers
- **sBTC Holder Rewards**: Fee sharing mechanism that rewards sBTC holders
- **Low Fees**: 0.3% swap fee with 70% going to liquidity providers and 30% to sBTC holders

## Smart Contract Structure

The StableSwap contract is built on the Stacks blockchain using Clarity language with the following components:

### Tokens

- **LP Token**: Represents liquidity provider shares in the pool
- **StableSwap Token**: Protocol governance token

### Core Functions

- **Swap**: Exchange between two assets in a pool
- **Add Liquidity**: Deposit assets to provide liquidity and earn LP tokens
- **Remove Liquidity**: Withdraw assets and burn LP tokens
- **Claim Rewards**: sBTC holders can claim their share of protocol fees

### Fee Distribution

- 0.3% trading fee on all swaps
- 70% of fees go to liquidity providers
- 30% of fees go to sBTC holders

## How to Use

### Create a Pool

Only the contract owner can create new pools:

```clarity
(contract-call? .stableswap create-pool 
  token-x-principal 
  token-y-principal 
  amplification-factor 
  pool-id)
```

### Swap Tokens

Users can swap between assets in an existing pool:

```clarity
(contract-call? .stableswap swap 
  pool-id 
  token-x-contract 
  token-y-contract 
  amount-in 
  minimum-amount-out)
```

### Add Liquidity

Provide liquidity to earn trading fees:

```clarity
(contract-call? .stableswap add-liquidity 
  pool-id 
  token-x-contract 
  token-y-contract 
  amount-x 
  amount-y 
  minimum-lp-tokens)
```

### Remove Liquidity

Withdraw assets from a pool:

```clarity
(contract-call? .stableswap remove-liquidity 
  pool-id 
  token-x-contract 
  token-y-contract 
  lp-amount 
  minimum-amount-x 
  minimum-amount-y)
```

### Claim Rewards (sBTC Holders)

sBTC holders can claim their share of protocol fees:

```clarity
(contract-call? .stableswap claim-rewards
  pool-id
  token-x-contract)
```

## Technical Details

### Curve Algorithm

StableSwap uses a specialized curve algorithm based on the invariant:

```
A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
```

Where:
- A: Amplification coefficient
- n: Number of tokens (2 in this implementation)
- x_i: Token balances
- D: Invariant value

This curve allows for efficient trading between assets with similar values while maintaining price stability.

### sBTC Holder Registration

sBTC holders need to be registered in the protocol to receive rewards:

```clarity
(contract-call? .stableswap register-sbtc-holder
  holder-principal
  amount)
```

Only the contract owner can register sBTC holders.

## Error Codes

- 100: Owner only operation
- 101: Insufficient balance
- 102: Insufficient liquidity
- 103: Slippage exceeded
- 104: Invalid amount
- 105: Pool imbalanced
- 106: Zero liquidity
- 107: Not authorized
- 108: Reward claim failed
- 109: sBTC holder list full
- 110: Invalid pool ID
- 111: Invalid token
- 112: Invalid amplification parameter
- 113: Invalid principal

## Security Considerations

- The contract uses mathematical operations that could potentially result in integer overflow
- Amplification factor must be set carefully to balance between efficiency and stability
- sBTC holder list is limited to 500 entries