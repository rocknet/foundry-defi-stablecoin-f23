1. (Relative Stability) Anchored or pegged -> $1.00
   1. Chainlink price feed.
   2. Set a function to exchange ETH and BTC -> $$$
2. Stability Mechanism (Minting): Algorithmic
   1. People can only mint stablecoin with enough collateral (coded)
3. Collateral: Exogenous (Crypto)
   1. wETH
   2. wBTC

Could use some more test coverage, and still a bit iffy on invariant fuzzing, but it's all working.
My redeem collateral invariant fuzz tests actually redeem (improvement).

Questions: 
- How to best choose the invariant for a protocol like this.
- Why were the contants private, but Patrick made public getters for them?
- When to use open invariants (Handler based testing with fail_on_revert=true seems superior)