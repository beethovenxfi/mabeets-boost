## maBEETS Boost

maBEETS Boost is a contract that allows users to sell their excess maturity to other users for a fee. Once a maBEETS relic reaches max maturity, it continues to accrue excess maturity in perpetuity. For simplicity, maBEETS Boost will always boost a relic to max maturity, there is no such thing as a partial boost. The contract ensures that the seller's relic always maintains the maximum maturity level after the offer is accepted.

## How it works

There are two parties, a `seller` and a `buyer`.

The `seller` creates an offer to sell their excess maturity to the `buyer`.

```solidity
maBeetsBoost.createOffer(relicId, feePerLevelBips);
```

The `buyer` accepts the offer, at which point the buyer's relic is merged into the seller's relic, and a new relic is created for the buyer using the `split` function.

```solidity
maBeetsBoost.acceptOffer(offerId);
```

The `feePerLevelBips` is the fee per level of maturity that the buyer will pay to the seller. The fee is paid in the form of a percentage of the relic's size. For example, if the fee is 0.1% per level, the buyer will pay

