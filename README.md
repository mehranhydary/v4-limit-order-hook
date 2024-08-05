## Liquidity operator for limit orders (via Uniswap V4 Hook)

## Mechanism Design

1. Place an order
2. Cancel an order (if it hasn't been filled yet)
3. Ability to withdraw / redeem output tokens after executing an order

None of these things are tied to the core Uniswap codebase. These will be public functions on the hook contract that anyone can call directly.

Once completed (order placed):

1. When price is right, how do we execute it? How do we do this as a part of a hook?
2. How do we know that the price is right? (When to execute)
3. How do we send / let the user redeem output from order

Assume there's a pool of tokens a and b. We will treat A as token 0, B as token 1. Assume tick is 500, tick means A is more valuable than B.

Types of TP orders that can be placed:

1. Sell amount of A as A gets more valuable than B
2. Sell some amount of B as B gets more valuable (A drops in value)

Case 1: Tick goes up further, beyond what it is right now (500)
Case 2: Tick goes up, below what is right now (500)

When do these tick values change? When trades take place

1. Alice places order to sell A for B when Tick = 600
2. Bob comes around and does a swap on the pool to buy A for B, increases the tick. Let's say after Bob's swap, new tick = 700.
3. Inside the `afterSwap` hook function, we can see this happening -> Tick just shifted from 500 to 700 because of Bob's swap.
4. Check if we have TP orders placed in the opposite direction in the rage that the tick was shifted. See Alice's order there.
5. We can execute Alice's order now that her requirements have been met.

## Assumptions

1. We are not concerned with gas costs / limits
   1.1. Bob will pay gas for Alice's order in the above example.
   1.2. We are not gonna limit how many orders we execute because of a price shift
2. We will ignore slippage requirements for placed limit orders
   2.1. When Alice places her order, ideally - she should also set some sort of slippages (sort of min token B to get back)
3. We are not gonna support pools that have native ETH . token as one of the currencies. We only support ERC-20:ERC20 pools.

# Mechanism Design continued

Prices are shifted every tiem a swap happens. We stubbted `afterSwap`. We need to calculate some sort of tick shift range. What was the last known tick? What is the new tick?

-   Hint #1: We need a way to keep track of the last known ticks

Something to be careful of:

-   Since we are executing a swap inside of `afterSwap`
    -> Swap will trigger `afterSwap` again
    -> This sort of reentrancy and recursion should not happen
    -> `afterSwap` should not be triggered if it is being entered because of us

-   As we are fulfilling our ordes, our orders are also causing a price shift

Example: Alice has an order to sell 5 ETH at 3000 USDC each, current price is like 2950
Bob does a swap to buy ETH which shifts price enough to make it 1 ETH = 3050 USDC

At this point, we will trigger Alice's order but fulfilling Alice's order will move the price back down

The problem that is caused by this, if we have multiple orders that exist in the original tick shift range (e.g. tick is 500, we have orders at tick 550 and 540, Bob does a swap, moves tick up to 600, enables 2 orders at range 550, 540, it is possible that the new tick before order 1 pushes 540 out of range again)

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
