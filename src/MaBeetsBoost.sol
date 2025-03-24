// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./interfaces/IReliquary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title MaBeetsBoost
 * @notice A contract that allows users to sell their excess maturity from fully matured
 * Reliquary positions to users with non-fully matured positions.
 */
contract MaBeetsBoost is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Offer {
        uint256 idx;
        address seller;
        uint256 relicId;
        uint256 feePerLevelBips; // Fee per level in basis points
        bool active;
    }

    // When the offer is fetched off-chain, we include metadata about the offer that is useful for the UI
    struct OfferWithMetadata {
        uint256 idx;
        address seller;
        uint256 relicId;
        uint256 feePerLevelBips;
        bool active;
        bool isOrphan;
        uint256 excessMaturity;
        uint256 relicSize;
        uint256 relicLevel;
        uint256 relicEntry;
        uint256 acceptedOffersCount;
    }

    // When the offer is accepted, we store a record of the offer for both the buyer and the seller
    // This is useful for displaying a user's history of accepted offers in the UI
    struct AcceptedOfferRecord {
        uint256 idx;
        address buyer;
        uint256 buyerRelicId;
        uint256 newBuyerRelicId;
        address seller;
        uint256 sellerRelicId;
        uint256 feePerLevelBips;
        uint256 amount;
        uint256 amountAfterFee;
        uint256 sellerFeeAmount;
        uint256 protocolFeeAmount;
        uint256 numLevelsBoosted;
        uint256 timestamp;
    }

    uint256 public constant MIN_FEE_PER_LEVEL_BIPS = 10; // 0.1%
    uint256 public constant MAX_FEE_PER_LEVEL_BIPS = 100; // 1%
    uint256 public constant MAX_PROTOCOL_FEE_BIPS = 5_000; // 50%
    uint256 public constant BIPS_DENOMINATOR = 10_000;
    // We set a minimum relic size to prevent any potential issues with rounding for very small relics
    uint256 public constant MIN_RELIC_SIZE = 1e18;

    uint256 public protocolFeeBips;
    address public protocolFeeRecipient;

    IReliquary public immutable reliquary;

    uint256 public immutable maBeetsPoolId;
    IERC20 public immutable maBeetsPoolToken;
    uint256 public immutable maBeetsMaxMaturityLevel;

    // Counter for generating unique offer IDs
    uint256 private _nextOfferIdx = 0;

    // Store the offers keyed on the relic id
    mapping(uint256 relicId => Offer) private _offers;

    // We create a list of offers to allow for iteration over all offers by off-chain tooling
    mapping(uint256 offerIdx => uint256 relicId) private _offerRelicIds;

    // We create a list of accepted offer records to allow for iteration over all accepted offers by off-chain tooling
    mapping(uint256 index => AcceptedOfferRecord) private _acceptedOfferRecords;
    uint256 private _nextAcceptedOfferRecordIdx = 0;

    // Store the accepted offers for both the buyer and the seller, keyed on the user address
    mapping(address user => mapping(uint256 index => uint256 acceptedOfferRecordIdx)) private
        _userAcceptedOfferRecordIndexes;
    mapping(address user => uint256 count) private _userAcceptedOfferRecordCount;

    // We store the number of accepted offers for each relic for use in the offer metadata
    mapping(uint256 relicId => uint256 acceptedOffersCount) private _relicNumAcceptedOffers;

    // Events
    event OfferCreated(address indexed seller, uint256 relicId, uint256 offerIdx, uint256 feePerLevelBips);
    event OfferCancelled(address indexed seller, uint256 relicId, uint256 offerIdx);
    event OfferAccepted(
        address indexed seller,
        address indexed buyer,
        uint256 sellerRelicId,
        uint256 buyerRelicId,
        uint256 offerIdx,
        uint256 sellerFeeAmount,
        uint256 protocolFeeAmount
    );

    // Errors
    error RelicNotFullyMatured();
    error OfferAlreadyActive();
    error OfferNotActive();
    error NotOfferOwner();
    error NotRelicOwner();
    error RelicTooSmall();
    error FeeTooHigh();
    error FeeTooLow();
    error RelicsNotFromSamePool();
    error WouldDecreaseSellersMaturity();
    error TransferFailed();
    error OfferNotOrphaned();
    error SellerNoLongerHoldsRelic();
    error RelicNotApproved();
    error SkipTooLarge();
    error MaxSizeCannotBeZero();
    error ProtocolFeeTooHigh();
    error NoAddressZero();
    error BuyerRelicFullyMatured();
    error RelicNotFromMaBeetsPool();
    error SellerAmountInvariantCheck();
    error BuyerAmountInvariantCheck();
    error RelicNotFullyMatureAfterSplit();

    constructor(
        address _reliquary,
        address _owner,
        uint256 _protocolFeeBips,
        address _protocolFeeRecipient,
        uint256 _maBeetsPoolId
    ) Ownable(_owner) {
        reliquary = IReliquary(_reliquary);
        maBeetsPoolId = _maBeetsPoolId;

        // The pool token and level info are immutable on reliquary, so its safe to store these values locally
        maBeetsPoolToken = IERC20(reliquary.poolToken(_maBeetsPoolId));
        LevelInfo memory levelInfo = reliquary.getLevelInfo(_maBeetsPoolId);
        maBeetsMaxMaturityLevel = levelInfo.requiredMaturities.length - 1;

        _setProtocolFeeBips(_protocolFeeBips);
        _setProtocolFeeRecipient(_protocolFeeRecipient);
    }

    /**
     * @notice Creates an offer to sell excess maturity
     * @param relicId The ID of the seller's fully matured relic
     * @param feePerLevelBips The fee per level in basis points to charge for the boost
     * @return offerId The ID of the created offer
     */
    function createOffer(uint256 relicId, uint256 feePerLevelBips) external nonReentrant returns (uint256) {
        // Check if there's already an active offer for this relic
        require(!_isOfferActive(relicId), OfferAlreadyActive());

        require(feePerLevelBips <= MAX_FEE_PER_LEVEL_BIPS, FeeTooHigh());
        require(feePerLevelBips >= MIN_FEE_PER_LEVEL_BIPS, FeeTooLow());

        // Verify the user owns the relic
        require(_isRelicOwnedBy(relicId, msg.sender), NotRelicOwner());
        // Verify this contract is approved to operate on the relic

        require(_isApprovedToOperateOnRelic(relicId), RelicNotApproved());
        require(_isRelicMaxMaturity(relicId), RelicNotFullyMatured());
        require(_isRelicFromMaBeetsPool(relicId), RelicNotFromMaBeetsPool());
        require(_isRelicLargeEnough(relicId), RelicTooSmall());

        uint256 offerIdx = _nextOfferIdx;

        _offers[relicId] =
            Offer({idx: offerIdx, seller: msg.sender, relicId: relicId, feePerLevelBips: feePerLevelBips, active: true});

        _offerRelicIds[offerIdx] = relicId;

        // Increment the next offer idx
        _nextOfferIdx++;

        emit OfferCreated(msg.sender, relicId, offerIdx, feePerLevelBips);

        return offerIdx;
    }

    /**
     * @notice Accept an offer to boost a relic's maturity
     * @param sellerRelicId The ID of the seller's relic
     * @param buyerRelicId The ID of the buyer's relic to boost
     */
    function acceptOffer(uint256 sellerRelicId, uint256 buyerRelicId)
        external
        nonReentrant
        returns (uint256 newBuyerRelicId)
    {
        Offer storage offer = _offers[sellerRelicId];
        address seller = _offers[sellerRelicId].seller;

        // Check if the offer is active
        require(_isOfferActive(sellerRelicId), OfferNotActive());

        // Verify seller still owns their relic
        require(_isRelicOwnedBy(sellerRelicId, seller), NotRelicOwner());
        // Verify this contract is approved to operate on the seller's relic
        require(_isApprovedToOperateOnRelic(sellerRelicId), RelicNotApproved());
        // Verify the seller's relic is still fully matured
        require(_isRelicMaxMaturity(sellerRelicId), RelicNotFullyMatured());
        // Verify the seller's relic is still large enough
        require(_isRelicLargeEnough(sellerRelicId), RelicTooSmall());

        // Verify buyer owns the relic they're using
        require(_isRelicOwnedBy(buyerRelicId, msg.sender), NotRelicOwner());
        // Verify this contract is approved to operate on the buyer's relic
        require(_isApprovedToOperateOnRelic(buyerRelicId), RelicNotApproved());
        // Verify the buyer's relic is from the MaBeets pool
        require(_isRelicFromMaBeetsPool(buyerRelicId), RelicNotFromMaBeetsPool());
        // Verify the buyer's relic is not fully matured
        require(!_isRelicMaxMaturity(buyerRelicId), BuyerRelicFullyMatured());
        // Verify the buyer's relic is large enough
        require(_isRelicLargeEnough(buyerRelicId), RelicTooSmall());

        // save the state of the positions before the operation
        PositionInfo memory sellerPosition = reliquary.getPositionForId(sellerRelicId);
        PositionInfo memory buyerPosition = reliquary.getPositionForId(buyerRelicId);
        uint256 sellerFeeAmount;
        uint256 protocolFeeAmount;

        // execute the operation state changes
        (newBuyerRelicId, sellerFeeAmount, protocolFeeAmount) = _acceptOffer(sellerRelicId, buyerRelicId);

        // While not strictly necessary, we enforce post operation invariant checks
        // As a means for communicating the expected outcome of the operation
        PositionInfo memory sellerPositionAfter = reliquary.getPositionForId(sellerRelicId);
        PositionInfo memory newBuyerPosition = reliquary.getPositionForId(newBuyerRelicId);

        require(_isRelicOwnedBy(sellerRelicId, seller), NotRelicOwner());
        require(_isRelicOwnedBy(newBuyerRelicId, msg.sender), NotRelicOwner());

        // The seller's relics should maintain max maturity after the offer is accepted. The properties of split ensure
        // that if the seller's relic is at max maturity, the new buyer's relic will also be at max maturity
        require(_isRelicMaxMaturity(sellerRelicId), RelicNotFullyMatureAfterSplit());

        // The amount of the seller's relic should never decrease
        require(sellerPositionAfter.amount == sellerPosition.amount + sellerFeeAmount, SellerAmountInvariantCheck());

        // The amount of the buyer's new relic should never increase
        require(
            newBuyerPosition.amount == buyerPosition.amount - sellerFeeAmount - protocolFeeAmount,
            BuyerAmountInvariantCheck()
        );

        _saveAcceptedOfferRecord(
            sellerRelicId,
            buyerRelicId,
            newBuyerRelicId,
            sellerFeeAmount,
            protocolFeeAmount,
            sellerPosition.level - buyerPosition.level
        );

        // The offer stays active until the seller cancels it, it will continue to accrue excess maturity

        emit OfferAccepted(
            seller, msg.sender, sellerRelicId, newBuyerRelicId, offer.idx, sellerFeeAmount, protocolFeeAmount
        );
    }

    function _acceptOffer(uint256 sellerRelicId, uint256 buyerRelicId)
        internal
        returns (uint256 newBuyerRelicId, uint256 sellerFeeAmount, uint256 protocolFeeAmount)
    {
        Offer storage offer = _offers[sellerRelicId];
        PositionInfo memory buyerPosition = reliquary.getPositionForId(buyerRelicId);

        // Calculate the fee amounts
        uint256 feeBips = (maBeetsMaxMaturityLevel - buyerPosition.level) * offer.feePerLevelBips;
        uint256 totalFeeAmount = (buyerPosition.amount * feeBips) / BIPS_DENOMINATOR;
        protocolFeeAmount = (totalFeeAmount * protocolFeeBips) / BIPS_DENOMINATOR;
        sellerFeeAmount = totalFeeAmount - protocolFeeAmount;

        // Merge the relics (this will combine both into sellerRelicId)
        reliquary.merge(buyerRelicId, sellerRelicId);

        // This transfers the new relic directly to the buyer
        // We leave the protocol fee amount in the seller's relic and process it below
        newBuyerRelicId = reliquary.split(sellerRelicId, buyerPosition.amount - totalFeeAmount, msg.sender);

        if (protocolFeeAmount > 0) {
            // Reliquary's withdraw function will send the tokens to msg.sender (this contract)
            reliquary.withdraw(protocolFeeAmount, sellerRelicId);
            maBeetsPoolToken.safeTransfer(protocolFeeRecipient, protocolFeeAmount);
        }
    }

    /**
     * @notice Cancels an existing offer
     * @param relicId The ID of the relic to cancel the offer for
     */
    function cancelOffer(uint256 relicId) external nonReentrant {
        Offer storage offer = _offers[relicId];

        // Check if the offer is active
        require(_isOfferActive(relicId), OfferNotActive());

        // Verify caller is the seller
        require(offer.seller == msg.sender, NotOfferOwner());

        // disable the offer
        offer.active = false;

        emit OfferCancelled(msg.sender, relicId, offer.idx);
    }

    /**
     * @notice Cancels an offer if the seller no longer owns the relic or the contract is not approved to operate on the relic
     * @param relicId The ID of the relic to cancel the offer for
     */
    function cancelOrphanOffer(uint256 relicId) external nonReentrant {
        Offer storage offer = _offers[relicId];

        require(_isOrphanOffer(relicId), OfferNotOrphaned());

        // disable the offer
        offer.active = false;

        emit OfferCancelled(offer.seller, offer.relicId, offer.idx);
    }

    /**
     * @notice Get the offer for a specific relic ID
     * @param relicId The relic ID to look up
     * @return offer The corresponding offer with metadata
     */
    function getOffer(uint256 relicId) public view returns (OfferWithMetadata memory) {
        PositionInfo memory position = reliquary.getPositionForId(relicId);
        uint256 maturity = block.timestamp - position.entry;
        uint256 excessMaturity = maturity > maBeetsMaxMaturityLevel ? maturity - maBeetsMaxMaturityLevel : 0;

        return OfferWithMetadata({
            idx: _offers[relicId].idx,
            seller: _offers[relicId].seller,
            relicId: _offers[relicId].relicId,
            feePerLevelBips: _offers[relicId].feePerLevelBips,
            active: _offers[relicId].active,
            isOrphan: _isOrphanOffer(relicId),
            excessMaturity: excessMaturity,
            relicSize: position.amount,
            relicLevel: position.level,
            relicEntry: position.entry,
            acceptedOffersCount: _relicNumAcceptedOffers[relicId]
        });
    }

    /**
     * @notice Get the offer for a specific offer ID
     * @param offerIdx The offer ID to look up
     * @return offer The corresponding offer with metadata
     */
    function getOfferByIdx(uint256 offerIdx) external view returns (OfferWithMetadata memory) {
        return getOffer(_offerRelicIds[offerIdx]);
    }

    /**
     * @notice Get all offers
     * @param skip The number of offers to skip
     * @param maxSize The maximum number of offers to return
     * @param reverseOrder Whether to return the offers in reverse order
     * @return offers The offers
     */
    function getOffers(uint256 skip, uint256 maxSize, bool reverseOrder)
        public
        view
        returns (OfferWithMetadata[] memory)
    {
        require(skip < _nextOfferIdx, SkipTooLarge());
        require(maxSize > 0, MaxSizeCannotBeZero());

        uint256 remaining = _nextOfferIdx - skip;
        uint256 size = remaining < maxSize ? remaining : maxSize;
        OfferWithMetadata[] memory items = new OfferWithMetadata[](size);

        for (uint256 i = 0; i < size; i++) {
            if (!reverseOrder) {
                // In chronological order we simply skip the first (older) entries
                items[i] = getOffer(_offerRelicIds[skip + i]);
            } else {
                // In reverse order we go back to front, skipping the last (newer) entries. Note that `remaining` will
                // equal the total count if `skip` is 0, meaning we'd start with the newest entry.
                items[i] = getOffer(_offerRelicIds[remaining - 1 - i]);
            }
        }

        return items;
    }

    function getOfferCount() public view returns (uint256) {
        return _nextOfferIdx;
    }

    function getAcceptedOfferRecords(uint256 skip, uint256 maxSize, bool reverseOrder)
        public
        view
        returns (AcceptedOfferRecord[] memory)
    {
        require(skip < _nextAcceptedOfferRecordIdx, SkipTooLarge());
        require(maxSize > 0, MaxSizeCannotBeZero());

        uint256 remaining = _nextAcceptedOfferRecordIdx - skip;
        uint256 size = remaining < maxSize ? remaining : maxSize;
        AcceptedOfferRecord[] memory items = new AcceptedOfferRecord[](size);

        for (uint256 i = 0; i < size; i++) {
            if (!reverseOrder) {
                // In chronological order we simply skip the first (older) entries
                items[i] = _acceptedOfferRecords[skip + i];
            } else {
                // In reverse order we go back to front, skipping the last (newer) entries. Note that `remaining` will
                // equal the total count if `skip` is 0, meaning we'd start with the newest entry.
                items[i] = _acceptedOfferRecords[remaining - 1 - i];
            }
        }

        return items;
    }

    function getAcceptedOfferRecordsCount() public view returns (uint256) {
        return _nextAcceptedOfferRecordIdx;
    }

    function getUserAcceptedOfferRecords(address user, uint256 skip, uint256 maxSize, bool reverseOrder)
        public
        view
        returns (AcceptedOfferRecord[] memory)
    {
        require(skip < _userAcceptedOfferRecordCount[user], SkipTooLarge());
        require(maxSize > 0, MaxSizeCannotBeZero());

        uint256 remaining = _userAcceptedOfferRecordCount[user] - skip;
        uint256 size = remaining < maxSize ? remaining : maxSize;
        AcceptedOfferRecord[] memory items = new AcceptedOfferRecord[](size);

        for (uint256 i = 0; i < size; i++) {
            if (!reverseOrder) {
                items[i] = _acceptedOfferRecords[_userAcceptedOfferRecordIndexes[user][skip + i]];
            } else {
                items[i] = _acceptedOfferRecords[_userAcceptedOfferRecordIndexes[user][remaining - 1 - i]];
            }
        }

        return items;
    }

    function getUserAcceptedOfferRecordsCount(address user) public view returns (uint256) {
        return _userAcceptedOfferRecordCount[user];
    }

    function setProtocolFeeBips(uint256 newProtocolFeeBips) external onlyOwner {
        _setProtocolFeeBips(newProtocolFeeBips);
    }

    function _setProtocolFeeBips(uint256 newProtocolFeeBips) internal {
        require(newProtocolFeeBips <= MAX_PROTOCOL_FEE_BIPS, ProtocolFeeTooHigh());

        protocolFeeBips = newProtocolFeeBips;
    }

    function setProtocolFeeRecipient(address newProtocolFeeRecipient) external onlyOwner {
        _setProtocolFeeRecipient(newProtocolFeeRecipient);
    }

    function _setProtocolFeeRecipient(address newProtocolFeeRecipient) internal {
        require(newProtocolFeeRecipient != address(0), NoAddressZero());

        protocolFeeRecipient = newProtocolFeeRecipient;
    }

    function _isApprovedToOperateOnRelic(uint256 relicId) internal view returns (bool) {
        return reliquary.isApprovedOrOwner(address(this), relicId);
    }

    function _isRelicMaxMaturity(uint256 relicId) internal view returns (bool) {
        return reliquary.getPositionForId(relicId).level == maBeetsMaxMaturityLevel;
    }

    function _isRelicOwnedBy(uint256 relicId, address owner) internal view returns (bool) {
        return reliquary.ownerOf(relicId) == owner;
    }

    function _isOfferActive(uint256 relicId) internal view returns (bool) {
        return _offers[relicId].active;
    }

    function _isRelicFromMaBeetsPool(uint256 relicId) internal view returns (bool) {
        return reliquary.getPositionForId(relicId).poolId == maBeetsPoolId;
    }

    function _isRelicLargeEnough(uint256 relicId) internal view returns (bool) {
        return reliquary.getPositionForId(relicId).amount >= MIN_RELIC_SIZE;
    }

    function _isOrphanOffer(uint256 relicId) internal view returns (bool) {
        if (!_isOfferActive(relicId)) {
            return false;
        }

        if (!_isApprovedToOperateOnRelic(relicId)) {
            return true;
        }

        if (!_isRelicOwnedBy(relicId, _offers[relicId].seller)) {
            return true;
        }

        if (!_isRelicLargeEnough(relicId)) {
            return true;
        }

        return false;
    }

    function _saveAcceptedOfferRecord(
        uint256 sellerRelicId,
        uint256 buyerRelicId,
        uint256 newBuyerRelicId,
        uint256 sellerFeeAmount,
        uint256 protocolFeeAmount,
        uint256 numLevelsBoosted
    ) internal {
        Offer memory offer = _offers[sellerRelicId];
        PositionInfo memory newBuyerPosition = reliquary.getPositionForId(newBuyerRelicId);
        address buyer = msg.sender;

        AcceptedOfferRecord memory record = AcceptedOfferRecord({
            idx: _nextAcceptedOfferRecordIdx,
            buyer: buyer,
            buyerRelicId: buyerRelicId,
            newBuyerRelicId: newBuyerRelicId,
            seller: offer.seller,
            sellerRelicId: sellerRelicId,
            feePerLevelBips: offer.feePerLevelBips,
            amount: newBuyerPosition.amount + sellerFeeAmount + protocolFeeAmount,
            amountAfterFee: newBuyerPosition.amount,
            sellerFeeAmount: sellerFeeAmount,
            protocolFeeAmount: protocolFeeAmount,
            numLevelsBoosted: numLevelsBoosted,
            timestamp: block.timestamp
        });

        _acceptedOfferRecords[_nextAcceptedOfferRecordIdx] = record;

        // Store the record for the buyer
        _userAcceptedOfferRecordIndexes[buyer][_userAcceptedOfferRecordCount[buyer]] = _nextAcceptedOfferRecordIdx;
        _userAcceptedOfferRecordCount[buyer]++;

        _userAcceptedOfferRecordIndexes[offer.seller][_userAcceptedOfferRecordCount[offer.seller]] =
            _nextAcceptedOfferRecordIdx;
        _userAcceptedOfferRecordCount[offer.seller]++;

        _nextAcceptedOfferRecordIdx++;

        _relicNumAcceptedOffers[sellerRelicId]++;
    }
}
