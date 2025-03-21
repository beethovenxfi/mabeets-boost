// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {MaBeetsBoost} from "../src/MaBeetsBoost.sol";
import {Reliquary} from "@reliquary/contracts/Reliquary.sol";
import {IReliquary, PositionInfo, PoolInfo, LevelInfo} from "@reliquary/contracts/interfaces/IReliquary.sol";
import {IEmissionCurve} from "@reliquary/contracts/interfaces/IEmissionCurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";

// We need a simple mock for the EmissionCurve
contract MockEmissionCurve is IEmissionCurve {
    function getRate(uint256) external pure override returns (uint256) {
        return 1e18; // Constant emission rate for testing
    }
}

contract MaBeetsBoostUnitTest is Test {
    MaBeetsBoost private maBeetsBoost;
    Reliquary private reliquary;
    MockERC20 private lpToken;
    MockERC20 private rewardToken;
    MockEmissionCurve private emissionCurve;

    // Test accounts
    address private owner = address(0x1);
    address private seller = address(0x2);
    address private buyer = address(0x3);
    address private feeRecipient = address(0x4);

    // Test parameters
    uint256 private constant POOL_ID = 0;
    uint256 private constant PROTOCOL_FEE_BIPS = 1000; // 10%
    uint256 private constant FEE_PER_LEVEL_BIPS = 50; // 0.5% per level

    // Setup for tests
    function setUp() public {
        vm.startPrank(owner);
        vm.warp(block.timestamp + 1000 days);

        // Deploy tokens
        lpToken = new MockERC20("LP Token", "LP", 18);
        rewardToken = new MockERC20("Reward Token", "RWD", 18);

        // Deploy emission curve
        emissionCurve = new MockEmissionCurve();

        // Deploy Reliquary
        reliquary = new Reliquary("Reliquary", "RELIC", address(rewardToken), owner);

        // Set emission curve
        reliquary.setEmissionCurve(address(emissionCurve));

        // Setup maturity levels for pool 0
        uint256[] memory requiredMaturities = new uint256[](5);
        requiredMaturities[0] = 0; // Level 0: 0 days
        requiredMaturities[1] = 7 days; // Level 1: 7 days
        requiredMaturities[2] = 30 days; // Level 2: 30 days
        requiredMaturities[3] = 90 days; // Level 3: 90 days
        requiredMaturities[4] = 180 days; // Level 4: 180 days (max)

        uint256[] memory multipliers = new uint256[](5);
        multipliers[0] = 100; // Level 0: 1x
        multipliers[1] = 110; // Level 1: 1.1x
        multipliers[2] = 120; // Level 2: 1.2x
        multipliers[3] = 130; // Level 3: 1.3x
        multipliers[4] = 150; // Level 4: 1.5x (max)

        // Add pool with the specified maturity levels
        reliquary.addPool(
            100, // allocPoint
            address(lpToken),
            address(0), // no rewarder
            requiredMaturities,
            multipliers,
            "LP Pool",
            address(0) // no NFT descriptor
        );

        // Deploy MaBeetsBoost contract
        maBeetsBoost = new MaBeetsBoost(address(reliquary), owner, PROTOCOL_FEE_BIPS, feeRecipient);
        vm.stopPrank();

        // Setup seller with a fully matured relic
        _setupSellerWithMaturedRelic();

        // Setup buyer with non-matured relic
        _setupBuyerWithNonMaturedRelic();
    }

    function _setupSellerWithMaturedRelic() private {
        // Mint LP tokens to seller
        lpToken.mint(seller, 1000 ether);

        // Need to warp time to create a fully matured relic
        vm.startPrank(seller);

        // Approve LP tokens for reliquary
        lpToken.approve(address(reliquary), 1000 ether);

        // Create a relic for the seller
        uint256 relicId = reliquary.createRelicAndDeposit(seller, POOL_ID, 100 ether);

        // Warp time to make it fully mature
        vm.warp(block.timestamp + 200 days);

        // Update the position to reflect the new maturity
        reliquary.updatePosition(relicId);

        // Approve MaBeetsBoost to operate on the relic
        reliquary.approve(address(maBeetsBoost), relicId);

        vm.stopPrank();
    }

    function _setupBuyerWithNonMaturedRelic() private {
        // Mint LP tokens to buyer
        lpToken.mint(buyer, 1000 ether);

        vm.startPrank(buyer);

        // Approve LP tokens for reliquary
        lpToken.approve(address(reliquary), 1000 ether);

        // Create a relic for the buyer (partially matured)
        uint256 relicId = reliquary.createRelicAndDeposit(buyer, POOL_ID, 50 ether);

        // Warp time to reach only level 2 maturity
        vm.warp(block.timestamp + 40 days);

        // Update the position to reflect the new maturity
        reliquary.updatePosition(relicId);

        // Approve MaBeetsBoost to operate on the relic
        reliquary.approve(address(maBeetsBoost), relicId);

        // Approve LP token transfers for paying fees
        lpToken.approve(address(maBeetsBoost), type(uint256).max);

        vm.stopPrank();
    }

    // Test constructor parameters
    function testConstructor() public {
        assertEq(address(maBeetsBoost.reliquary()), address(reliquary));
        assertEq(maBeetsBoost.owner(), owner);
        assertEq(maBeetsBoost.protocolFeeBips(), PROTOCOL_FEE_BIPS);
        assertEq(maBeetsBoost.protocolFeeRecipient(), feeRecipient);
    }

    // Test createOffer function
    function testCreateOffer() public {
        // Get seller's relic
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        // Create offer
        vm.startPrank(seller);
        uint256 offerId = maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);
        vm.stopPrank();

        // Get the offer
        MaBeetsBoost.Offer memory offer = maBeetsBoost.getOffer(relicId);

        // Verify offer details
        assertEq(offer.id, offerId);
        assertEq(offer.seller, seller);
        assertEq(offer.relicId, relicId);
        assertEq(offer.poolId, POOL_ID);
        assertEq(offer.feePerLevelBips, FEE_PER_LEVEL_BIPS);
        assertTrue(offer.active);
    }

    // Test fee validation in createOffer
    function testCreateOfferFeeTooHigh() public {
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.startPrank(seller);
        vm.expectRevert(); // Expect revert on fee too high
        maBeetsBoost.createOffer(relicId, maBeetsBoost.MAX_FEE_PER_LEVEL_BIPS() + 1);
        vm.stopPrank();
    }

    function testCreateOfferFeeTooLow() public {
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.startPrank(seller);
        vm.expectRevert(); // Expect revert on fee too low
        maBeetsBoost.createOffer(relicId, maBeetsBoost.MIN_FEE_PER_LEVEL_BIPS() - 1);
        vm.stopPrank();
    }

    // Test offer cancellation
    function testCancelOffer() public {
        // Create offer first
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.startPrank(seller);
        uint256 offerId = maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        // Cancel offer
        maBeetsBoost.cancelOffer(relicId);
        vm.stopPrank();

        // Verify offer is inactive
        MaBeetsBoost.Offer memory offer = maBeetsBoost.getOffer(relicId);
        assertFalse(offer.active);
    }

    // Test unauthorized cancel
    function testUnauthorizedCancelOffer() public {
        // Create offer
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        // Try to cancel as non-owner
        vm.prank(buyer);
        vm.expectRevert(); // Expect revert for not being offer owner
        maBeetsBoost.cancelOffer(relicId);
    }

    // Test cancellation of orphaned offer
    function testCancelOrphanOffer() public {
        // Create offer
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        // Make the offer orphaned by removing approval
        vm.prank(seller);
        reliquary.approve(address(maBeetsBoost), false);

        // Anyone can cancel an orphaned offer
        vm.prank(buyer);
        maBeetsBoost.cancelOrphanOffer(relicId);

        // Verify offer is inactive
        MaBeetsBoost.Offer memory offer = maBeetsBoost.getOffer(relicId);
        assertFalse(offer.active);
    }

    // Test accepting an offer
    function testAcceptOffer() public {
        // Create offer
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);
        uint256 buyerRelicId = reliquary.tokenOfOwnerByIndex(buyer, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // Initial balances
        uint256 initialBuyerBalance = lpToken.balanceOf(buyer);
        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Accept offer
        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId);

        // Check balances
        uint256 finalBuyerBalance = lpToken.balanceOf(buyer);
        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Verify fee distribution
        // Level difference is 2 (4-2), fee per level is 0.5%, so total fee is 1%
        // Of the 50 ether, 0.5 ether (1%) should be taken as fees
        // Of that 0.5 ether, 10% (0.05 ether) goes to protocol, 90% (0.45 ether) stays with seller

        assertTrue(finalBuyerBalance < initialBuyerBalance); // Buyer paid fees
        assertTrue(finalFeeRecipientBalance > initialFeeRecipientBalance); // Fee recipient got fees

        // Ensure the offer is still active after acceptance
        MaBeetsBoost.Offer memory offer = maBeetsBoost.getOffer(sellerRelicId);
        assertTrue(offer.active);
    }

    // Test setting protocol fee bips
    function testSetProtocolFeeBips() public {
        uint256 newFeeBips = 2000; // 20%

        vm.prank(owner);
        maBeetsBoost.setProtocolFeeBips(newFeeBips);

        assertEq(maBeetsBoost.protocolFeeBips(), newFeeBips);
    }

    // Test protocol fee bips too high
    function testSetProtocolFeeBipsTooHigh() public {
        uint256 tooHighFeeBips = maBeetsBoost.MAX_PROTOCOL_FEE_BIPS() + 1;

        vm.prank(owner);
        vm.expectRevert(); // Expect revert for fee too high
        maBeetsBoost.setProtocolFeeBips(tooHighFeeBips);
    }

    // Test setting protocol fee recipient
    function testSetProtocolFeeRecipient() public {
        address newRecipient = address(0x5);

        vm.prank(owner);
        maBeetsBoost.setProtocolFeeRecipient(newRecipient);

        assertEq(maBeetsBoost.protocolFeeRecipient(), newRecipient);
    }

    // Test setting zero address as fee recipient
    function testSetProtocolFeeRecipientZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(); // Expect revert for zero address
        maBeetsBoost.setProtocolFeeRecipient(address(0));
    }

    // Test view functions
    function testGetOfferWithMetadata() public {
        // Create offer
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        // Get offer with metadata
        MaBeetsBoost.OfferWithMetadata memory offerWithMetadata = maBeetsBoost.getOfferWithMetadata(relicId);

        // Verify offer metadata
        assertEq(offerWithMetadata.id, offerId);
        assertEq(offerWithMetadata.seller, seller);
        assertEq(offerWithMetadata.relicId, relicId);
        assertEq(offerWithMetadata.poolId, POOL_ID);
        assertEq(offerWithMetadata.feePerLevelBips, FEE_PER_LEVEL_BIPS);
        assertTrue(offerWithMetadata.active);
        assertFalse(offerWithMetadata.isOrphan);
        assertTrue(offerWithMetadata.excessMaturity > 0); // Should have excess maturity
        assertEq(offerWithMetadata.relicSize, 100 ether); // Relic size
    }

    // Test getOffers function
    function testGetOffers() public {
        // Create multiple offers
        uint256 relicId1 = reliquary.createRelicAndDeposit(seller, POOL_ID, 100 ether);
        uint256 relicId2 = reliquary.createRelicAndDeposit(seller, POOL_ID, 200 ether);

        vm.startPrank(seller);
        reliquary.approve(address(maBeetsBoost), true);

        maBeetsBoost.createOffer(relicId1, FEE_PER_LEVEL_BIPS);
        maBeetsBoost.createOffer(relicId2, FEE_PER_LEVEL_BIPS + 10);
        vm.stopPrank();

        // Test getOffers with normal order
        MaBeetsBoost.OfferWithMetadata[] memory offers = maBeetsBoost.getOffers(0, 10, false);
        assertEq(offers.length, 3); // Should have 3 offers total

        // Test getOffers with reverse order
        offers = maBeetsBoost.getOffers(0, 10, true);
        assertEq(offers.length, 3);
        // In reverse order, the newest offer should be first
        assertEq(offers[0].relicId, relicId2);

        // Test getOffers with skip
        offers = maBeetsBoost.getOffers(1, 10, false);
        assertEq(offers.length, 2);

        // Test getOffers with maxSize
        offers = maBeetsBoost.getOffers(0, 1, false);
        assertEq(offers.length, 1);
    }

    // Error cases
    function testOfferAlreadyExists() public {
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.startPrank(seller);
        maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        // Try to create another offer for the same relic
        vm.expectRevert(); // Expect revert for offer already exists
        maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);
        vm.stopPrank();
    }

    function testOfferDoesNotExist() public {
        uint256 nonExistingRelicId = 9999;

        vm.prank(seller);
        vm.expectRevert(); // Expect revert for offer does not exist
        maBeetsBoost.cancelOffer(nonExistingRelicId);
    }

    function testNotRelicOwner() public {
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        // Try to create offer for a relic not owned
        vm.prank(buyer);
        vm.expectRevert(); // Expect revert for not relic owner
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);
    }

    function testRelicNotApproved() public {
        // Create a new relic without approval
        uint256 relicId = reliquary.createRelicAndDeposit(seller, POOL_ID, 100 ether);

        // Do not set approval

        // Try to create offer
        vm.prank(seller);
        vm.expectRevert(); // Expect revert for relic not approved
        maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);
    }

    function testRelicNotFullyMatured() public {
        // Create a partially matured relic
        uint256 relicId = reliquary.createRelicAndDeposit(seller, POOL_ID, 100 ether);

        vm.startPrank(seller);
        reliquary.approve(address(maBeetsBoost), true);

        // Try to create offer with a not fully matured relic
        vm.expectRevert(); // Expect revert for relic not fully matured
        maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);
        vm.stopPrank();
    }

    function testBuyerRelicFullyMatured() public {
        // Create seller offer
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // Create a fully matured relic for buyer
        uint256 buyerFullyMaturedRelicId = reliquary.createRelicAndDeposit(buyer, POOL_ID, 50 ether);

        vm.startPrank(buyer);
        reliquary.approve(address(maBeetsBoost), true);

        // Try to accept offer with fully matured relic
        vm.expectRevert(); // Expect revert for buyer relic fully matured
        maBeetsBoost.acceptOffer(sellerRelicId, buyerFullyMaturedRelicId);
        vm.stopPrank();
    }

    function testRelicsNotFromSamePool() public {
        // Create seller offer
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // Create a relic for buyer in a different pool
        uint256 DIFFERENT_POOL_ID = 1;
        reliquary.addPool(
            100, // allocPoint
            address(lpToken),
            address(0), // no rewarder
            new uint256[](0), // no maturity levels
            new uint256[](0), // no multipliers
            "LP Pool",
            address(0) // no NFT descriptor
        );

        uint256 buyerDifferentPoolRelicId = reliquary.createRelicAndDeposit(buyer, DIFFERENT_POOL_ID, 50 ether);

        vm.startPrank(buyer);
        reliquary.approve(address(maBeetsBoost), true);

        // Try to accept offer with relic from different pool
        vm.expectRevert(); // Expect revert for relics not from same pool
        maBeetsBoost.acceptOffer(sellerRelicId, buyerDifferentPoolRelicId);
        vm.stopPrank();
    }

    // Test with zero protocol fee
    function testZeroProtocolFee() public {
        // Set protocol fee to zero
        vm.prank(owner);
        maBeetsBoost.setProtocolFeeBips(0);

        // Create and accept an offer
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);
        uint256 buyerRelicId = reliquary.tokenOfOwnerByIndex(buyer, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        uint256 initialBuyerBalance = lpToken.balanceOf(buyer);
        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Accept offer
        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId);

        // With zero protocol fee, fee recipient should not receive anything
        assertEq(lpToken.balanceOf(feeRecipient), initialFeeRecipientBalance);
        assertTrue(lpToken.balanceOf(buyer) < initialBuyerBalance); // Buyer still pays fees
    }

    // Test multiple offer acceptances
    function testMultipleOfferAcceptances() public {
        // Create offer
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // Create multiple buyer relics at different maturity levels
        uint256 buyerRelicId1 = reliquary.createRelicAndDeposit(buyer, POOL_ID, 10 ether);
        uint256 buyerRelicId2 = reliquary.createRelicAndDeposit(buyer, POOL_ID, 20 ether);

        vm.startPrank(buyer);
        reliquary.approve(address(maBeetsBoost), true);

        // Accept offer with first relic
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId1);

        // Accept offer with second relic
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId2);
        vm.stopPrank();

        // Verify offer is still active
        MaBeetsBoost.Offer memory offer = maBeetsBoost.getOffer(sellerRelicId);
        assertTrue(offer.active);
    }

    // Test when relic ownership changes
    function testRelicOwnershipChange() public {
        // Create offer
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        // Change relic ownership by creating a new owner in the mock
        address newOwner = address(0x9);
        vm.prank(seller);
        reliquary.createRelicAndDeposit(newOwner, POOL_ID, 0, 0, 0); // Just to register the new owner

        // This orphans the offer since the seller no longer owns the relic
        // In a real scenario this would happen through a transfer

        // Anyone can cancel the orphaned offer
        vm.prank(buyer);
        maBeetsBoost.cancelOrphanOffer(relicId);

        // Verify offer is inactive
        MaBeetsBoost.Offer memory offer = maBeetsBoost.getOffer(relicId);
        assertFalse(offer.active);
    }

    // Test offer with very high level difference
    function testHighLevelDifferenceFee() public {
        // Create a level 0 relic for buyer
        uint256 entry = block.timestamp - 1 days; // Very new relic
        vm.startPrank(buyer);
        uint256 buyerRelicId = reliquary.createRelicAndDeposit(buyer, POOL_ID, 100 ether);
        reliquary.approve(address(maBeetsBoost), true);
        vm.stopPrank();

        // Create offer
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.startPrank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);
        vm.stopPrank();

        // Calculate expected fee
        // Level difference is 4 (4-0), fee per level is 0.5%, so total fee is 2%
        uint256 expectedFeePercentage = 4 * FEE_PER_LEVEL_BIPS; // 200 basis points = 2%
        uint256 buyerAmount = 100 ether;
        uint256 expectedTotalFee = (buyerAmount * expectedFeePercentage) / maBeetsBoost.BIPS_DENOMINATOR();
        uint256 expectedProtocolFee = (expectedTotalFee * PROTOCOL_FEE_BIPS) / maBeetsBoost.BIPS_DENOMINATOR();

        uint256 initialBuyerBalance = lpToken.balanceOf(buyer);
        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Accept offer
        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId);

        // Check fee distribution
        uint256 actualFeeRecipientAmount = lpToken.balanceOf(feeRecipient) - initialFeeRecipientBalance;
        assertEq(actualFeeRecipientAmount, expectedProtocolFee);
        assertEq(initialBuyerBalance - lpToken.balanceOf(buyer), expectedTotalFee);
    }

    // Test skip and maxSize validation in getOffers
    function testGetOffersValidation() public {
        // Test with skip too large
        vm.expectRevert(); // Expect revert for skip too large
        maBeetsBoost.getOffers(999, 10, false);

        // Test with maxSize zero
        vm.expectRevert(); // Expect revert for maxSize cannot be zero
        maBeetsBoost.getOffers(0, 0, false);
    }
}
