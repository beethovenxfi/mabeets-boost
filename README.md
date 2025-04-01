# maBEETS Boost

maBEETS Boost allows users to sell their excess maturity to other users for a fee. Once a maBEETS relic reaches max maturity, it continues to accrue excess maturity in perpetuity. This contract allows users to leverage their excess maturity and for new maBEETS holders to pay a fee to "skip" a portion or all of the maturity period. When an offer is accepted, the buyer can decide how many levels to boost, and will pay a fee per level of maturity gained. The contract ensures that the seller's relic always maintains the maximum maturity level after the offer is accepted.

## Reliquary

maBEETS governance positions leverage Reliquary, a contract developed by Cod3x (formerly the Byte Masons).

The Reliquary contract used by maBEETS is deployed to Sonic mainnet, here: [0x973670ce19594F857A7cD85EE834c7a74a941684](https://sonicscan.org/address/0x973670ce19594f857a7cd85ee834c7a74a941684#code).

The version of Reliquary deployed can be found [here](https://github.com/beethovenxfi/Reliquary). There are more recent versions of Reliquary that introduce additional functionality, but is not in use for maBEETS.

## How it works

There are two parties, a `seller` and a `buyer`.

The `seller` creates an offer to sell their excess maturity to any `buyer` by calling the `createOffer` function. The seller defines the `feePerLevelBips`, which is the fee per level of maturity that the buyer will pay to the seller.

```solidity
maBeetsBoost.createOffer(relicId, feePerLevelBips);
```

A `buyer` can accept an offer at any time by specifying the seller's relic ID, their own relic ID, and the number of levels to boost.

```solidity
maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, boostToLevel);
```

When an offer is accepted, the following occurs:
1. We calculate the relic size needed to boost the buyer's relic to the desired level given the seller's relic maturity.
2. We create a temporary relic that holds the amount needed to boost the buyer's relic to the desired level.
3. We merge the buyer's relic into the temporary relic.
4. We call split on the temporary relic, creating a new relic for the buyer that is boosted to the desired level and holds their original relic size minus the fee. The protocol fee amount is left in the temporary relic.
5. We merge the temporary relic back into the seller's relic, burning the temporary relic.
6. We withdraw the protocol fee amount from the seller's relic and send it to the protocol fee recipient.

Since the seller's relic continues to accrue excess maturity, the offer stays active until the seller explicitly cancels it or it becomes an orphaned offer, at which point anyone can call `cancelOrphanedOffer`.

To cancel an offer, the seller can call `cancelOffer` at any time.

```solidity
maBeetsBoost.cancelOffer(relicId);
```

In the instance that the seller's offer is orphaned, anyone can call `cancelOrphanedOffer` to cancel the offer.

```solidity
maBeetsBoost.cancelOrphanedOffer(relicId);
```

An offer is considered orphaned if any of the below are true:
- The MaBeetsBoost contract is not approved to operate on the relic.
- The relic is no longer owned by the seller that created the offer.
- The relic's size is less than the minimum relic size (1e18).
- The relic is no longer at max maturity.

## Considerations

From an implementation perspective, it would be simpler if the MaBeetsBoost contract would take custody of the seller's relic once an offer is created. This would remove any concerns about the offer becoming orphaned. But, this introduces potential risk vectors and require various integrations to ensure that the seller's relic is still included in all governance mechanisms. As such, it was decided that the seller would keep custody of their own relic at all times, and the MaBeetsBoost contract uses the approval mechanism to operate on both the seller's and buyer's relic.

