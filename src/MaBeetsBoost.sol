// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./interfaces/IReliquary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MaBeetsBoost
 * @notice A contract that allows users to sell their excess maturity from fully matured
 * Reliquary positions to users with non-fully matured positions.
 */
contract MaBeetsBoost is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Offer {
        uint256 id;
        address seller;
        uint256 relicId;
        uint256 poolId;
        uint256 feePerLevelBips; // Fee per level in basis points
        bool active;
    }

    struct OfferWithMetadata {
        uint256 id;
        address seller;
        uint256 relicId;
        uint256 poolId;
        uint256 feePerLevelBips;
        bool active;
        bool isOrphan;
        uint256 excessMaturity;
        uint256 relicSize;
    }

    uint256 public constant MIN_FEE_PER_LEVEL_BIPS = 10; // 0.1%
    uint256 public constant MAX_FEE_PER_LEVEL_BIPS = 100; // 1%
    uint256 public constant MAX_PROTOCOL_FEE_BIPS = 5_000; // 50%
    uint256 public constant BIPS_DENOMINATOR = 10_000;

    uint256 public protocolFeeBips;
    address public protocolFeeRecipient;

    // Reliquary contract
    IReliquary public immutable reliquary;

    // Counter for generating unique offer IDs
    uint256 public nextOfferId = 0;

    // Mapping from relicId => Offer
    mapping(uint256 relicId => Offer) private _offers;

    // Mapping from offerId => relicId
    mapping(uint256 offerId => uint256 relicId) public offerRelicIds;

    // Events
    event OfferCreated(
        address indexed seller, uint256 relicId, uint256 poolId, uint256 offerId, uint256 feePerLevelBips
    );
    event OfferCancelled(address indexed seller, uint256 relicId, uint256 offerId);
    event OfferAccepted(
        address indexed seller,
        address indexed buyer,
        uint256 sellerRelicId,
        uint256 buyerRelicId,
        uint256 offerId,
        uint256 sellerFeeAmount,
        uint256 protocolFeeAmount
    );

    // Errors
    error RelicNotFullyMatured();
    error OfferAlreadyExists();
    error OfferDoesNotExist();
    error NotOfferOwner();
    error NotRelicOwner();
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

    constructor(address _reliquary, address _owner, uint256 _protocolFeeBips, address _protocolFeeRecipient)
        Ownable(_owner)
    {
        reliquary = IReliquary(_reliquary);

        _setProtocolFeeBips(_protocolFeeBips);
        _setProtocolFeeRecipient(_protocolFeeRecipient);
    }

    /**
     * @notice Creates an offer to sell excess maturity
     * @param relicId The ID of the seller's fully matured relic
     * @param feePerLevelBips The fee per level in basis points to charge for the boost
     * @return offerId The ID of the created offer
     */
    function createOffer(uint256 relicId, uint256 feePerLevelBips) external nonReentrant returns (uint256 offerId) {
        // Check if there's already an active offer for this relic
        require(!_offerExists(relicId), OfferAlreadyExists());

        require(feePerLevelBips <= MAX_FEE_PER_LEVEL_BIPS, FeeTooHigh());
        require(feePerLevelBips >= MIN_FEE_PER_LEVEL_BIPS, FeeTooLow());

        // Verify the user owns the relic
        require(_isRelicOwnedBy(relicId, msg.sender), NotRelicOwner());

        // Verify this contract is approved to operate on the relic
        require(_isApprovedToOperateOnRelic(relicId), RelicNotApproved());

        require(_isRelicMaxMaturity(relicId), RelicNotFullyMatured());

        PositionInfo memory position = reliquary.getPositionForId(relicId);

        // Generate a new offer ID
        offerId = nextOfferId;
        // Increment the next offer ID
        nextOfferId++;

        // Create the offer
        _offers[relicId] = Offer({
            id: offerId,
            seller: msg.sender,
            relicId: relicId,
            poolId: position.poolId,
            feePerLevelBips: feePerLevelBips,
            active: true
        });

        offerRelicIds[offerId] = relicId;

        emit OfferCreated(msg.sender, relicId, position.poolId, offerId, feePerLevelBips);
    }

    /**
     * @notice Accept an offer to boost a relic's maturity
     * @param sellerRelicId The ID of the seller's relic
     * @param buyerRelicId The ID of the buyer's relic to boost
     */
    function acceptOffer(uint256 sellerRelicId, uint256 buyerRelicId) external nonReentrant {
        Offer storage offer = _offers[sellerRelicId];

        // Check if the offer exists
        require(_offerExists(sellerRelicId), OfferDoesNotExist());

        address seller = offer.seller;

        // Verify seller still owns their relic
        require(_isRelicOwnedBy(sellerRelicId, seller), NotRelicOwner());
        // Verify this contract is approved to operate on the seller's relic
        require(_isApprovedToOperateOnRelic(sellerRelicId), RelicNotApproved());
        // Verify the seller relic is still fully matured
        require(_isRelicMaxMaturity(sellerRelicId), RelicNotFullyMatured());

        // Verify buyer owns the relic they're using
        require(_isRelicOwnedBy(buyerRelicId, msg.sender), NotRelicOwner());
        // Verify this contract is approved to operate on the buyer's relic
        require(_isApprovedToOperateOnRelic(buyerRelicId), RelicNotApproved());

        PositionInfo memory sellerPosition = reliquary.getPositionForId(sellerRelicId);
        PositionInfo memory buyerPosition = reliquary.getPositionForId(buyerRelicId);

        // Make sure both relics are from the same pool
        require(sellerPosition.poolId == buyerPosition.poolId, RelicsNotFromSamePool());
        // Verify the buyers relic is not fully matured
        require(sellerPosition.level > buyerPosition.level, BuyerRelicFullyMatured());

        // Calculate the fee amounts
        uint256 feeBips = (sellerPosition.level - buyerPosition.level) * offer.feePerLevelBips;
        uint256 totalFeeAmount = (buyerPosition.amount * feeBips) / BIPS_DENOMINATOR;
        uint256 protocolFeeAmount = (totalFeeAmount * protocolFeeBips) / BIPS_DENOMINATOR;
        uint256 sellerFeeAmount = totalFeeAmount - protocolFeeAmount;

        // Merge the relics (this will combine both into sellerRelicId)
        reliquary.merge(buyerRelicId, sellerRelicId);

        // This transfers the new relic directly to the buyer
        // We leave the protocol fee amount in the seller's relic and process it below
        uint256 newBuyerRelicId = reliquary.split(sellerRelicId, buyerPosition.amount - totalFeeAmount, msg.sender);

        // The relic should maintain max maturity after the split
        require(_isRelicMaxMaturity(sellerRelicId), RelicNotFullyMatured());

        if (protocolFeeAmount > 0) {
            // Reliquary's withdraw function will send the tokens to msg.sender (this contract)
            reliquary.withdraw(protocolFeeAmount, sellerRelicId);
            IERC20(reliquary.poolToken(offer.poolId)).safeTransfer(protocolFeeRecipient, protocolFeeAmount);
        }

        // The offer stays active until the seller cancels it, it will continue to accrue excess maturity

        emit OfferAccepted(
            seller, msg.sender, sellerRelicId, newBuyerRelicId, offer.id, sellerFeeAmount, protocolFeeAmount
        );
    }

    /**
     * @notice Cancels an existing offer
     * @param relicId The ID of the relic to cancel the offer for
     */
    function cancelOffer(uint256 relicId) external nonReentrant {
        Offer storage offer = _offers[relicId];

        // Check if the offer exists
        require(_offerExists(relicId), OfferDoesNotExist());

        // Verify caller is the seller
        require(offer.seller == msg.sender, NotOfferOwner());

        // Clear the offer
        offer.active = false;

        emit OfferCancelled(msg.sender, relicId, offer.id);
    }

    /**
     * @notice Cancels an offer if the seller no longer owns the relic or the contract is not approved to operate on the relic
     * @param relicId The ID of the relic to cancel the offer for
     */
    function cancelOrphanOffer(uint256 relicId) external nonReentrant {
        Offer storage offer = _offers[relicId];

        require(_isOrphanOffer(relicId), OfferNotOrphaned());

        // Clear the offer
        offer.active = false;

        emit OfferCancelled(offer.seller, offer.relicId, offer.id);
    }

    /**
     * @notice Get the offer for a specific relic ID
     * @param relicId The relic ID to look up
     * @return offer The corresponding offer, or null if no active offer exists
     */
    function getOffer(uint256 relicId) external view returns (Offer memory) {
        return _offers[relicId];
    }

    /**
     * @notice Get the offer for a specific offer ID
     * @param offerId The offer ID to look up
     * @return offer The corresponding offer, or null if no active offer exists
     */
    function getOfferById(uint256 offerId) external view returns (Offer memory) {
        return _offers[offerRelicIds[offerId]];
    }

    function getOfferWithMetadata(uint256 relicId) public view returns (OfferWithMetadata memory) {
        PositionInfo memory position = reliquary.getPositionForId(relicId);
        LevelInfo memory levelInfo = reliquary.getLevelInfo(position.poolId);
        uint256 maturity = block.timestamp - position.entry;
        uint256 maxMaturity = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length - 1];
        uint256 excessMaturity = maturity > maxMaturity ? maturity - maxMaturity : 0;

        return OfferWithMetadata({
            id: _offers[relicId].id,
            seller: _offers[relicId].seller,
            relicId: _offers[relicId].relicId,
            poolId: _offers[relicId].poolId,
            feePerLevelBips: _offers[relicId].feePerLevelBips,
            active: _offers[relicId].active,
            isOrphan: _isOrphanOffer(relicId),
            excessMaturity: excessMaturity,
            relicSize: position.amount
        });
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
        require(skip < nextOfferId, SkipTooLarge());
        require(maxSize > 0, MaxSizeCannotBeZero());

        uint256 remaining = nextOfferId - skip;
        uint256 size = remaining < maxSize ? remaining : maxSize;
        OfferWithMetadata[] memory items = new OfferWithMetadata[](size);

        for (uint256 i = 0; i < size; i++) {
            if (!reverseOrder) {
                // In chronological order we simply skip the first (older) entries
                items[i] = getOfferWithMetadata(offerRelicIds[skip + i]);
            } else {
                // In reverse order we go back to front, skipping the last (newer) entries. Note that `remaining` will
                // equal the total count if `skip` is 0, meaning we'd start with the newest entry.
                items[i] = getOfferWithMetadata(offerRelicIds[remaining - 1 - i]);
            }
        }

        return items;
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
        PositionInfo memory position = reliquary.getPositionForId(relicId);
        LevelInfo memory levelInfo = reliquary.getLevelInfo(position.poolId);

        return position.level == levelInfo.requiredMaturities.length - 1;
    }

    function _isRelicOwnedBy(uint256 relicId, address owner) internal view returns (bool) {
        return reliquary.ownerOf(relicId) == owner;
    }

    function _offerExists(uint256 relicId) internal view returns (bool) {
        return _offers[relicId].active;
    }

    function _isOrphanOffer(uint256 relicId) internal view returns (bool) {
        if (!_offerExists(relicId)) {
            return false;
        }

        if (!_isApprovedToOperateOnRelic(relicId)) {
            return true;
        }

        if (!_isRelicOwnedBy(relicId, _offers[relicId].seller)) {
            return true;
        }

        return false;
    }
}
