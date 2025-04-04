// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {MaBeetsBoost} from "../src/MaBeetsBoost.sol";
import {IReliquary, PositionInfo, PoolInfo, LevelInfo} from "../src/interfaces/IReliquary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

contract MaBeetsBoostUnitTest is Test {
    MaBeetsBoost private maBeetsBoost;
    IReliquary private reliquary;
    IERC20 private lpToken;

    // Test accounts
    address private owner = address(0x1);
    address private seller = address(0x2);
    uint256 private sellerRelicId;
    address private buyer = address(0x3);
    uint256 private buyerRelicId;
    address private feeRecipient = address(0x4);
    address private user1 = address(0x5); // Additional test user
    uint256 private user1RelicId;
    address private user2 = address(0x6); // Additional test user
    uint256 private user2RelicId;
    address private seller2 = address(0x7); // Additional test user
    uint256 private seller2RelicId;

    // Test parameters
    uint256 private constant PROTOCOL_FEE_BIPS = 1000; // 10%
    uint256 private constant FEE_PER_LEVEL_BIPS = 50; // 0.5% per level
    uint256 private constant MAX_MATURED_LEVEL = 10;

    // Sonic blockchain specific constants
    string private SONIC_RPC_URL = vm.envString("SONIC_RPC_URL");
    address private RELIQUARY_ADDRESS = 0x973670ce19594F857A7cD85EE834c7a74a941684;
    uint256 private MABEETS_POOL_ID = 0; // First pool ID in Reliquary
    address private BEETS_TREASURY = 0xc5E0250037195850E4D987CA25d6ABa68ef5fEe8;

    // Store fork ID
    uint256 private forkId;

    uint256 timeForMaxMaturity;

    // Setup for tests
    function setUp() public {
        // Create a fork of Sonic blockchain
        forkId = vm.createSelectFork(SONIC_RPC_URL, 15032705);

        // Get the already deployed Reliquary
        reliquary = IReliquary(RELIQUARY_ADDRESS);

        // Fetch the LP token for the test pool
        lpToken = IERC20(reliquary.poolToken(MABEETS_POOL_ID));

        // Deploy MaBeetsBoost contract
        vm.startPrank(owner);
        maBeetsBoost = new MaBeetsBoost(
            address(reliquary), owner, PROTOCOL_FEE_BIPS, feeRecipient, MABEETS_POOL_ID, FEE_PER_LEVEL_BIPS
        );
        vm.stopPrank();

        // Get the time for max maturity
        LevelInfo memory levelInfo = reliquary.getLevelInfo(MABEETS_POOL_ID);
        timeForMaxMaturity = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length - 1] + 1 days;

        // fully matured relics
        sellerRelicId = _createRelic(seller, 100 ether);
        seller2RelicId = _createRelic(seller2, 1000 ether);
        user1RelicId = _createRelic(user1, 100 ether);

        // Warp time to max maturity
        vm.warp(block.timestamp + timeForMaxMaturity);

        // non-matured relic
        buyerRelicId = _createRelic(buyer, 50 ether);
        uint256 partialMaturity = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length / 2];

        // Warp time to reach partial maturity
        vm.warp(block.timestamp + partialMaturity);

        user2RelicId = _createRelic(user2, 75 ether);
        vm.warp(block.timestamp + 1 days); // Just 1 day maturity

        // Update the positions to reflect the new maturity
        reliquary.updatePosition(sellerRelicId);
        reliquary.updatePosition(seller2RelicId);
        reliquary.updatePosition(user1RelicId);
        reliquary.updatePosition(user2RelicId);
        reliquary.updatePosition(buyerRelicId);
    }

    function _createRelic(address user, uint256 amount) private returns (uint256 relicId) {
        _distributeLpTokens(user, amount);

        vm.startPrank(user);

        lpToken.approve(address(reliquary), amount);
        relicId = reliquary.createRelicAndDeposit(user, MABEETS_POOL_ID, amount);

        // Approve MaBeetsBoost to operate on the relic
        reliquary.approve(address(maBeetsBoost), relicId);

        vm.stopPrank();
    }

    function _createFullyMatureRelic(address user, uint256 amount) private returns (uint256 relicId) {
        relicId = _createRelic(user, amount);

        vm.warp(block.timestamp + timeForMaxMaturity);

        reliquary.updatePosition(relicId);
    }

    function _createPartiallyMatureRelic(address user, uint256 amount) private returns (uint256 relicId) {
        relicId = _createRelic(user, amount);

        LevelInfo memory levelInfo = reliquary.getLevelInfo(MABEETS_POOL_ID);
        uint256 partialMaturity = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length / 2];

        vm.warp(block.timestamp + partialMaturity);

        reliquary.updatePosition(relicId);
    }

    function _distributeLpTokens(address to, uint256 amount) internal {
        vm.startPrank(BEETS_TREASURY);
        lpToken.transfer(to, amount);
        vm.stopPrank();
    }

    // Test constructor parameters
    function testConstructor() public {
        assertEq(address(maBeetsBoost.reliquary()), address(reliquary));
        assertEq(maBeetsBoost.owner(), owner);
        assertEq(maBeetsBoost.protocolFeeBips(), PROTOCOL_FEE_BIPS);
        assertEq(maBeetsBoost.protocolFeeRecipient(), feeRecipient);
    }

    function testCreateOffer() public {
        // Create offer
        vm.startPrank(seller);
        uint256 offerIdx = maBeetsBoost.createOffer(sellerRelicId);
        vm.stopPrank();

        // Get the offer
        MaBeetsBoost.OfferWithMetadata memory offer = maBeetsBoost.getOffer(sellerRelicId);

        // Verify offer details
        assertEq(offer.idx, offerIdx);
        assertEq(offer.seller, seller);
        assertEq(offer.relicId, sellerRelicId);
        assertTrue(offer.active);
    }

    function testCancelOffer() public {
        vm.startPrank(seller);
        uint256 offerId = maBeetsBoost.createOffer(sellerRelicId);

        // Cancel offer
        maBeetsBoost.cancelOffer(sellerRelicId);
        vm.stopPrank();

        // Verify offer is inactive
        assertFalse(maBeetsBoost.getOffer(sellerRelicId).active);
    }

    function testUnauthorizedCancelOffer() public {
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Try to cancel as non-owner
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.NotOfferOwner.selector));
        maBeetsBoost.cancelOffer(sellerRelicId);
        vm.stopPrank();
    }

    function testCancelOrphanOfferWithoutApproval() public {
        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(sellerRelicId);

        assertTrue(maBeetsBoost.getOffer(sellerRelicId).active);

        // Make the offer orphaned by removing approval
        vm.prank(seller);
        reliquary.approve(address(0), sellerRelicId);

        // Anyone can cancel an orphaned offer
        vm.prank(buyer);
        maBeetsBoost.cancelOrphanOffer(sellerRelicId);

        // Verify offer is inactive
        assertFalse(maBeetsBoost.getOffer(sellerRelicId).active);
    }

    function testCancelOrphanOfferOwnerChanged() public {
        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(sellerRelicId);

        assertTrue(maBeetsBoost.getOffer(sellerRelicId).active);

        // Make the offer orphaned by transferring it to another user
        vm.prank(seller);
        reliquary.transferFrom(seller, user1, sellerRelicId);

        // Anyone can cancel an orphaned offer
        vm.prank(buyer);
        maBeetsBoost.cancelOrphanOffer(sellerRelicId);

        // Verify offer is inactive
        assertFalse(maBeetsBoost.getOffer(sellerRelicId).active);
    }

    function testCancelOrphanRelicTooSmall() public {
        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(sellerRelicId);

        assertTrue(maBeetsBoost.getOffer(sellerRelicId).active);

        PositionInfo memory position = reliquary.getPositionForId(sellerRelicId);

        // Make the offer orphaned by making it too small
        vm.prank(seller);
        reliquary.withdraw(position.amount - 1e18 + 1, sellerRelicId);

        // Anyone can cancel an orphaned offer
        vm.prank(buyer);
        maBeetsBoost.cancelOrphanOffer(sellerRelicId);

        // Verify offer is inactive
        assertFalse(maBeetsBoost.getOffer(sellerRelicId).active);
    }

    function testCancelOrphanRelicNotMatured() public {
        vm.startPrank(seller);
        uint256 offerId = maBeetsBoost.createOffer(sellerRelicId);

        assertTrue(maBeetsBoost.getOffer(sellerRelicId).active);

        PositionInfo memory position = reliquary.getPositionForId(sellerRelicId);
        uint256 amountToDeposit = position.amount * 2;
        lpToken.approve(address(reliquary), amountToDeposit);
        vm.stopPrank();

        _distributeLpTokens(seller, amountToDeposit);
        // Make the offer orphaned by depositing enough to reduce the maturity level
        vm.prank(seller);
        reliquary.deposit(amountToDeposit, sellerRelicId);

        // Anyone can cancel an orphaned offer
        vm.prank(buyer);
        maBeetsBoost.cancelOrphanOffer(sellerRelicId);

        // Verify offer is inactive
        assertFalse(maBeetsBoost.getOffer(sellerRelicId).active);
    }

    // Test non-orphan offer cancellation failure
    function testCancelNonOrphanOfferFailure() public {
        // Create a valid offer
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(relicId);

        // Try to cancel as orphan when it's not orphaned
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.OfferNotOrphaned.selector));
        maBeetsBoost.cancelOrphanOffer(relicId);
        vm.stopPrank();
    }

    function testAcceptOffer() public {
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Record initial balances and states
        PositionInfo memory buyerPositionBefore = reliquary.getPositionForId(buyerRelicId);
        PositionInfo memory sellerPositionBefore = reliquary.getPositionForId(sellerRelicId);
        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);
        uint256 initialBuyerLevel = buyerPositionBefore.level;

        // Accept the offer
        vm.prank(buyer);
        uint256 newBuyerRelicId = maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        // Verify states after acceptance
        PositionInfo memory buyerPositionAfter = reliquary.getPositionForId(newBuyerRelicId);
        PositionInfo memory sellerPositionAfter = reliquary.getPositionForId(sellerRelicId);
        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Verify fee recipient received protocol fees
        assertTrue(finalFeeRecipientBalance > initialFeeRecipientBalance);

        // Verify the new buyer's relic is smaller than the original
        assertLt(buyerPositionAfter.amount, buyerPositionBefore.amount);

        // Verify the seller's relic size has increased
        assertGt(sellerPositionAfter.amount, sellerPositionBefore.amount);

        // Ensure the offer is still active after acceptance
        MaBeetsBoost.OfferWithMetadata memory offer = maBeetsBoost.getOffer(sellerRelicId);
        assertTrue(offer.active);
    }

    // Test attempt to accept offer with fully matured buyer relic
    function testAcceptOfferWithFullyMaturedBuyerRelic() public {
        // Create offer
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Create a fully matured relic for buyer
        vm.startPrank(buyer);

        // Warp time to fully mature the buyer's relic
        LevelInfo memory levelInfo = reliquary.getLevelInfo(MABEETS_POOL_ID);
        uint256 timeNeeded = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length - 1] + 1 days;
        vm.warp(block.timestamp + timeNeeded);

        reliquary.updatePosition(buyerRelicId);

        // Try to accept offer with fully matured relic
        vm.expectRevert(); // Expect revert for fully matured buyer relic
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    // Test protocol fee changes
    function testSetProtocolFee() public {
        uint256 newProtocolFee = 2000; // 20%

        vm.prank(owner);
        maBeetsBoost.setProtocolFeeBips(newProtocolFee);

        assertEq(maBeetsBoost.protocolFeeBips(), newProtocolFee);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        PositionInfo memory sellerPosition = reliquary.getPositionForId(sellerRelicId);
        PositionInfo memory buyerPosition = reliquary.getPositionForId(buyerRelicId);
        uint256 levelDifference = sellerPosition.level - buyerPosition.level;
        uint256 feeBips = levelDifference * FEE_PER_LEVEL_BIPS;
        uint256 expectedTotalFee = (buyerPosition.amount * feeBips) / 10000;
        uint256 expectedProtocolFee = (expectedTotalFee * newProtocolFee) / 10000;

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);
        uint256 protocolFeeReceived = finalFeeRecipientBalance - initialFeeRecipientBalance;

        // The protocol receives the correct fee amount
        assertEq(protocolFeeReceived, expectedProtocolFee);
    }

    // Test setting protocol fee recipient
    function testSetProtocolFeeRecipient() public {
        address newFeeRecipient = address(0x9);

        vm.prank(owner);
        maBeetsBoost.setProtocolFeeRecipient(newFeeRecipient);

        assertEq(maBeetsBoost.protocolFeeRecipient(), newFeeRecipient);

        // Test fees go to new recipient

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        uint256 initialFeeRecipientBalance = lpToken.balanceOf(newFeeRecipient);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        uint256 finalFeeRecipientBalance = lpToken.balanceOf(newFeeRecipient);

        assertGt(finalFeeRecipientBalance, initialFeeRecipientBalance);
    }

    // Test zero protocol fee
    function testZeroProtocolFee() public {
        // Set protocol fee to zero
        vm.prank(owner);
        maBeetsBoost.setProtocolFeeBips(0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Fee recipient receives no fees when protocol fee is zero
        assertEq(finalFeeRecipientBalance, initialFeeRecipientBalance);
    }

    function testMaxProtocolFeeValidation() public {
        uint256 feeToHigh = maBeetsBoost.MAX_PROTOCOL_FEE_BIPS() + 1;

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.ProtocolFeeTooHigh.selector));
        maBeetsBoost.setProtocolFeeBips(feeToHigh);
        vm.stopPrank();
    }

    function testFeeRecipientZeroAddressValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.NoAddressZero.selector));
        maBeetsBoost.setProtocolFeeRecipient(address(0));
        vm.stopPrank();
    }

    function testGetOffer() public {
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        PositionInfo memory position = reliquary.getPositionForId(sellerRelicId);
        MaBeetsBoost.OfferWithMetadata memory offerMeta = maBeetsBoost.getOffer(sellerRelicId);

        assertEq(offerMeta.seller, seller);
        assertEq(offerMeta.relicId, sellerRelicId);
        assertTrue(offerMeta.active);
        assertFalse(offerMeta.isOrphan);
        assertEq(offerMeta.relicSize, position.amount);
        assertEq(offerMeta.relicLevel, position.level);
        assertEq(offerMeta.relicEntry, position.entry);
        assertEq(offerMeta.acceptedOffersCount, 0);
    }

    function testGetOfferByIdx() public {
        vm.prank(seller);
        uint256 offerIdx = maBeetsBoost.createOffer(sellerRelicId);

        MaBeetsBoost.OfferWithMetadata memory offer = maBeetsBoost.getOfferByIdx(offerIdx);

        assertEq(offer.idx, offerIdx, "Offer ID should match");
        assertEq(offer.seller, seller, "Seller should match");
        assertEq(offer.relicId, sellerRelicId, "Relic ID should match");
    }

    // Test getOffers pagination
    function testGetOffersPagination() public {
        // Create several offers
        // Setup seller 1 (existing)
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Setup seller 2 (user1)
        vm.prank(user1);
        maBeetsBoost.createOffer(user1RelicId);

        // Test getOffers with pagination
        MaBeetsBoost.OfferWithMetadata[] memory offers = maBeetsBoost.getOffers(0, 1, false);
        assertEq(offers.length, 1, "Should return only 1 offer");
        assertEq(offers[0].seller, seller, "First offer should be from seller");

        offers = maBeetsBoost.getOffers(1, 1, false);
        assertEq(offers.length, 1, "Should return only 1 offer");
        assertEq(offers[0].seller, user1, "Second offer should be from user1");

        // Test reverse order
        offers = maBeetsBoost.getOffers(0, 2, true);
        assertEq(offers.length, 2, "Should return 2 offers");
        assertEq(offers[0].seller, user1, "First offer in reverse should be from user1");
        assertEq(offers[1].seller, seller, "Second offer in reverse should be from seller");
    }

    function testMultipleOfferAcceptances() public {
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // First buyer accepts
        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        vm.warp(block.timestamp + timeForMaxMaturity);
        user2RelicId = _createRelic(user2, 100 ether);

        // Second buyer (user2) accepts
        vm.prank(user2);
        maBeetsBoost.acceptOffer(sellerRelicId, user2RelicId, MAX_MATURED_LEVEL);

        // Verify offer is still active
        MaBeetsBoost.OfferWithMetadata memory offer = maBeetsBoost.getOffer(sellerRelicId);
        assertTrue(offer.active, "Offer should remain active after multiple acceptances");
        assertEq(offer.acceptedOffersCount, 2, "Offer should have 2 accepted offers");
    }

    // Test acceptance fee calculation with different level gaps
    function testFeeCalculationWithDifferentLevelGaps() public {
        PositionInfo memory sellerPosition = reliquary.getPositionForId(sellerRelicId);

        // We need to mature the seller's relic enough that it can boost a level 0
        vm.warp(block.timestamp + timeForMaxMaturity * 4);

        // create a relic that is level 0
        uint256 relicId = _createRelic(user2, 100 ether);
        vm.warp(block.timestamp + 1 days);

        reliquary.updatePosition(relicId);
        reliquary.updatePosition(sellerRelicId);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        PositionInfo memory user2Position = reliquary.getPositionForId(relicId);

        // Record initial states
        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Accept the offer
        vm.prank(user2);
        maBeetsBoost.acceptOffer(sellerRelicId, relicId, MAX_MATURED_LEVEL);

        PositionInfo memory sellerPositionAfter = reliquary.getPositionForId(sellerRelicId);
        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);
        uint256 protocolFeeReceived = finalFeeRecipientBalance - initialFeeRecipientBalance;

        // Calculate expected fee based on level difference
        uint256 levelDiff = sellerPosition.level - user2Position.level;
        uint256 feeBips = levelDiff * FEE_PER_LEVEL_BIPS;
        uint256 totalFee = (user2Position.amount * feeBips) / 10000;
        uint256 expectedProtocolFee = (totalFee * PROTOCOL_FEE_BIPS) / 10000;
        uint256 expectedSellerFee = totalFee - expectedProtocolFee;

        assertEq(user2Position.level, 0, "User2 should be at level 0");

        assertEq(protocolFeeReceived, expectedProtocolFee, "Protocol fee should match expected amount");
        assertEq(
            sellerPositionAfter.amount,
            sellerPosition.amount + expectedSellerFee,
            "Seller relic size should match expected amount"
        );
    }

    // Test getAcceptedOfferRecords basic functionality
    function testGetAcceptedOfferRecords() public {
        // Create an offer from seller
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        vm.warp(block.timestamp + timeForMaxMaturity);
        user2RelicId = _createRelic(user2, 100 ether);

        vm.prank(user2);
        maBeetsBoost.acceptOffer(sellerRelicId, user2RelicId, MAX_MATURED_LEVEL);

        // Get all accepted offer records
        MaBeetsBoost.AcceptedOfferRecord[] memory records = maBeetsBoost.getAcceptedOfferRecords(0, 10, false);

        // Verify we have the expected number of records
        assertEq(records.length, 2, "Should have 2 accepted offer records");

        // Verify the content of the first record
        assertEq(records[0].idx, 0, "First record should have ID 0");
        assertEq(records[0].buyer, buyer, "First record buyer should match");
        assertEq(records[0].seller, seller, "First record seller should match");
        assertEq(records[0].sellerRelicId, sellerRelicId, "First record seller relic ID should match");

        // Verify the content of the second record
        assertEq(records[1].idx, 1, "Second record should have ID 1");
        assertEq(records[1].buyer, user2, "Second record buyer should match");
        assertEq(records[1].seller, seller, "Second record seller should match");
    }

    // Test getAcceptedOfferRecords pagination
    function testGetAcceptedOfferRecordsPagination() public {
        // Create and accept multiple offers
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        vm.prank(seller2);
        maBeetsBoost.createOffer(seller2RelicId);

        vm.prank(user2);
        maBeetsBoost.acceptOffer(seller2RelicId, user2RelicId, MAX_MATURED_LEVEL);

        // Test pagination - get first record
        MaBeetsBoost.AcceptedOfferRecord[] memory firstPageRecords = maBeetsBoost.getAcceptedOfferRecords(0, 1, false);
        assertEq(firstPageRecords.length, 1, "Should return only 1 record");
        assertEq(firstPageRecords[0].idx, 0, "First page should contain record with ID 0");

        // Test pagination - get second record
        MaBeetsBoost.AcceptedOfferRecord[] memory secondPageRecords = maBeetsBoost.getAcceptedOfferRecords(1, 1, false);
        assertEq(secondPageRecords.length, 1, "Should return only 1 record");
        assertEq(secondPageRecords[0].idx, 1, "Second page should contain record with ID 1");

        // Test reverse order
        MaBeetsBoost.AcceptedOfferRecord[] memory reverseRecords = maBeetsBoost.getAcceptedOfferRecords(0, 2, true);
        assertEq(reverseRecords.length, 2, "Should return 2 records");
        assertEq(reverseRecords[0].idx, 1, "First record in reverse should be ID 1");
        assertEq(reverseRecords[1].idx, 0, "Second record in reverse should be ID 0");
    }

    // Test getUserAcceptedOfferRecords
    function testGetUserAcceptedOfferRecords() public {
        // Create and accept multiple offers
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        vm.prank(seller2);
        maBeetsBoost.createOffer(seller2RelicId);

        vm.prank(user2);
        maBeetsBoost.acceptOffer(seller2RelicId, user2RelicId, MAX_MATURED_LEVEL);

        // Get records for specific users
        MaBeetsBoost.AcceptedOfferRecord[] memory buyerRecords =
            maBeetsBoost.getUserAcceptedOfferRecords(buyer, 0, 10, false);
        MaBeetsBoost.AcceptedOfferRecord[] memory sellerRecords =
            maBeetsBoost.getUserAcceptedOfferRecords(seller, 0, 10, false);
        MaBeetsBoost.AcceptedOfferRecord[] memory seller2Records =
            maBeetsBoost.getUserAcceptedOfferRecords(seller2, 0, 10, false);
        MaBeetsBoost.AcceptedOfferRecord[] memory user2Records =
            maBeetsBoost.getUserAcceptedOfferRecords(user2, 0, 10, false);

        // Verify buyer records
        assertEq(buyerRecords.length, 1, "Buyer should have 1 record");
        assertEq(buyerRecords[0].buyer, buyer, "Record buyer should be buyer");

        // Verify seller records
        assertEq(sellerRecords.length, 1, "Seller should have 1 record");
        assertEq(sellerRecords[0].seller, seller, "Record seller should be seller");

        // Verify user1 records
        assertEq(seller2Records.length, 1, "User1 should have 1 record");
        assertEq(seller2Records[0].seller, seller2, "Record seller should be seller2");

        // Verify user2 records
        assertEq(user2Records.length, 1, "User2 should have 1 record");
        assertEq(user2Records[0].buyer, user2, "Record buyer should be user2");
    }

    // Test getUserAcceptedOfferRecords pagination and reverse order
    function testGetUserAcceptedOfferRecordsPaginationAndOrder() public {
        // Create first offer from seller
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Buyer accepts first offer
        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        // Advance time to create another relic for seller
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1 days);

        // Create another relic for the seller
        uint256 secondSellerRelicId = _createFullyMatureRelic(seller, 100 ether);

        vm.warp(block.timestamp + timeForMaxMaturity);

        user2RelicId = _createRelic(user2, 100 ether);

        // Create second offer from seller
        vm.prank(seller);
        maBeetsBoost.createOffer(secondSellerRelicId);

        // User2 accepts second offer
        vm.prank(user2);
        maBeetsBoost.acceptOffer(secondSellerRelicId, user2RelicId, MAX_MATURED_LEVEL);

        // Test seller's records with pagination
        MaBeetsBoost.AcceptedOfferRecord[] memory firstPageSellerRecords =
            maBeetsBoost.getUserAcceptedOfferRecords(seller, 0, 1, false);
        assertEq(firstPageSellerRecords.length, 1, "Should return only 1 record");

        MaBeetsBoost.AcceptedOfferRecord[] memory secondPageSellerRecords =
            maBeetsBoost.getUserAcceptedOfferRecords(seller, 1, 1, false);
        assertEq(secondPageSellerRecords.length, 1, "Should return only 1 record");

        // Test reverse order
        MaBeetsBoost.AcceptedOfferRecord[] memory reverseSellerRecords =
            maBeetsBoost.getUserAcceptedOfferRecords(seller, 0, 2, true);
        assertEq(reverseSellerRecords.length, 2, "Should return 2 records");
        assertEq(reverseSellerRecords[0].idx, 1, "First record in reverse should be the latest one");
        assertEq(reverseSellerRecords[1].idx, 0, "Second record in reverse should be the first one");
    }

    // Test invalid input scenarios
    function testInvalidInputsForOfferRecords() public {
        // Create and accept an offer to have at least one record
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        // Test skipping too many records
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.SkipTooLarge.selector));
        maBeetsBoost.getAcceptedOfferRecords(10, 1, false);

        // Test maxSize = 0
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.MaxSizeCannotBeZero.selector));
        maBeetsBoost.getAcceptedOfferRecords(0, 0, false);

        // Test user records with too large skip
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.SkipTooLarge.selector));
        maBeetsBoost.getUserAcceptedOfferRecords(buyer, 10, 1, false);

        // Test user records with maxSize = 0
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.MaxSizeCannotBeZero.selector));
        maBeetsBoost.getUserAcceptedOfferRecords(buyer, 0, 0, false);

        // Test getting records for a user with no records
        address userWithNoRecords = address(0x123);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.SkipTooLarge.selector));
        maBeetsBoost.getUserAcceptedOfferRecords(userWithNoRecords, 0, 1, false);
    }

    // Test creating an offer with relic that's too small
    function testCreateOfferWithRelicTooSmall() public {
        // Create a new small relic for seller
        uint256 smallAmount = maBeetsBoost.MIN_RELIC_SIZE() - 1;
        uint256 smallRelicId = _createRelic(seller, smallAmount);

        // Warp time to max maturity to make it eligible for offering
        vm.warp(block.timestamp + timeForMaxMaturity);
        reliquary.updatePosition(smallRelicId);

        // Try to create an offer with a relic that's too small
        vm.startPrank(seller);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.RelicTooSmall.selector));
        maBeetsBoost.createOffer(smallRelicId);
        vm.stopPrank();
    }

    // Test accepting an offer with buyer's relic that's too small
    function testAcceptOfferWithBuyerRelicTooSmall() public {
        // Create an offer from seller

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Create a small relic for buyer
        uint256 smallAmount = maBeetsBoost.MIN_RELIC_SIZE() - 1;
        uint256 smallBuyerRelicId = _createRelic(buyer, smallAmount);

        // Ensure it's not fully matured, but has some maturity
        vm.warp(block.timestamp + 1 days);
        reliquary.updatePosition(smallBuyerRelicId);

        // Try to accept the offer with a relic that's too small
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.RelicTooSmall.selector));
        maBeetsBoost.acceptOffer(sellerRelicId, smallBuyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    // Test exact minimum relic size
    function testExactMinimumRelicSize() public {
        // Create a relic with exactly the minimum size
        uint256 exactMinAmount = maBeetsBoost.MIN_RELIC_SIZE();
        uint256 exactMinRelicId = _createRelic(seller, exactMinAmount);

        // Warp time to max maturity
        vm.warp(block.timestamp + timeForMaxMaturity * 2);
        reliquary.updatePosition(exactMinRelicId);

        // This should succeed
        vm.startPrank(seller);
        uint256 offerIdx = maBeetsBoost.createOffer(exactMinRelicId);
        vm.stopPrank();

        // Verify the offer was created successfully
        MaBeetsBoost.OfferWithMetadata memory offer = maBeetsBoost.getOffer(exactMinRelicId);
        assertEq(offer.idx, offerIdx);
        assertTrue(offer.active);

        // Test buyer with exactly minimum size relic
        uint256 exactMinBuyerRelicId = _createRelic(buyer, exactMinAmount);

        // Some maturity but not full
        vm.warp(block.timestamp + 1 days);
        reliquary.updatePosition(exactMinBuyerRelicId);

        // This should succeed
        vm.prank(buyer);
        maBeetsBoost.acceptOffer(exactMinRelicId, exactMinBuyerRelicId, MAX_MATURED_LEVEL);
    }

    // Test for seller accepting their own offer (valid but unusual case)
    function testSellerAcceptsOwnOffer() public {
        // Create a second relic for the seller with lower maturity
        uint256 sellerSecondRelicId = _createRelic(seller, 50 ether);

        // Create offer with the fully matured relic
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Approve the second relic
        vm.prank(seller);
        reliquary.approve(address(maBeetsBoost), sellerSecondRelicId);

        // Seller accepts their own offer with their second relic
        vm.prank(seller);
        uint256 newRelicId = maBeetsBoost.acceptOffer(sellerRelicId, sellerSecondRelicId, MAX_MATURED_LEVEL);

        // Verify both relics are still owned by seller
        assertEq(reliquary.ownerOf(sellerRelicId), seller);
        assertEq(reliquary.ownerOf(newRelicId), seller);
    }

    // Test buyer with almost-max maturity (one level below max)
    function testBuyerWithOneMaturityLevelBeforeMax() public {
        // Create offer
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Create a new relic for the buyer
        uint256 almostMaxRelicId = _createRelic(buyer, 50 ether);

        // Get the level info to determine time needed for almost-max maturity
        LevelInfo memory levelInfo = reliquary.getLevelInfo(MABEETS_POOL_ID);
        uint256 almostMaxLevel = levelInfo.requiredMaturities.length - 2; // One level before max
        uint256 timeNeeded = levelInfo.requiredMaturities[almostMaxLevel];

        // Warp time to reach almost-max maturity
        vm.warp(block.timestamp + timeNeeded);
        reliquary.updatePosition(almostMaxRelicId);

        // Approve the relic
        vm.prank(buyer);
        reliquary.approve(address(maBeetsBoost), almostMaxRelicId);

        // Buyer accepts the offer with almost-max maturity relic
        vm.prank(buyer);
        uint256 newBuyerRelicId = maBeetsBoost.acceptOffer(sellerRelicId, almostMaxRelicId, MAX_MATURED_LEVEL);

        // Verify the new relic is at max maturity
        PositionInfo memory newPosition = reliquary.getPositionForId(newBuyerRelicId);
        assertEq(newPosition.level, levelInfo.requiredMaturities.length - 1, "New relic should be at max maturity");
    }

    // Test the getter functions for accepted offer records count
    function testAcceptedOfferRecordCountGetters() public {
        // Create and accept multiple offers to generate records
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);

        vm.prank(seller2);
        maBeetsBoost.createOffer(seller2RelicId);

        vm.prank(user2);
        maBeetsBoost.acceptOffer(seller2RelicId, user2RelicId, MAX_MATURED_LEVEL);

        // Test global count
        uint256 globalCount = maBeetsBoost.getAcceptedOfferRecordsCount();
        assertEq(globalCount, 2, "Should have 2 accepted offer records in total");

        // Test user-specific counts
        uint256 buyerCount = maBeetsBoost.getUserAcceptedOfferRecordsCount(buyer);
        assertEq(buyerCount, 1, "Buyer should have 1 accepted offer record");

        uint256 sellerCount = maBeetsBoost.getUserAcceptedOfferRecordsCount(seller);
        assertEq(sellerCount, 1, "Seller should have 1 accepted offer record");

        uint256 seller2Count = maBeetsBoost.getUserAcceptedOfferRecordsCount(seller2);
        assertEq(seller2Count, 1, "Seller2 should have 1 accepted offer record");

        uint256 user2Count = maBeetsBoost.getUserAcceptedOfferRecordsCount(user2);
        assertEq(user2Count, 1, "User2 should have 1 accepted offer record");

        // Check count for user with no records
        address userWithNoRecords = address(0x123);
        uint256 noRecordsCount = maBeetsBoost.getUserAcceptedOfferRecordsCount(userWithNoRecords);
        assertEq(noRecordsCount, 0, "User with no records should have count 0");
    }

    // Test getting total offer count
    function testGetOfferCount() public {
        // Create multiple offers
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        vm.prank(seller2);
        maBeetsBoost.createOffer(seller2RelicId);

        vm.prank(user1);
        maBeetsBoost.createOffer(user1RelicId);

        // Check the total count
        uint256 offerCount = maBeetsBoost.getOfferCount();
        assertEq(offerCount, 3, "Should have 3 offers in total");

        // Cancel one offer and verify count doesn't change (only active status changes)
        vm.prank(seller);
        maBeetsBoost.cancelOffer(sellerRelicId);

        uint256 offerCountAfterCancel = maBeetsBoost.getOfferCount();
        assertEq(offerCountAfterCancel, 3, "Offer count should not change after cancellation");
    }

    // Test edge case: accept offer when buyer and seller maturity difference is only 1 level
    function testAcceptOfferWithMinimalMaturityDifference() public {
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Create a new relic for the buyer with high but not max maturity
        uint256 highMaturityRelicId = _createRelic(buyer, 75 ether);

        // Get the level info to determine time needed for high maturity
        LevelInfo memory levelInfo = reliquary.getLevelInfo(MABEETS_POOL_ID);
        uint256 secondHighestLevel = levelInfo.requiredMaturities.length - 2; // One level before max
        uint256 timeNeeded = levelInfo.requiredMaturities[secondHighestLevel];

        // Warp time to reach high maturity (one level below max)
        vm.warp(block.timestamp + timeNeeded);
        reliquary.updatePosition(highMaturityRelicId);
        PositionInfo memory highMaturityPosition = reliquary.getPositionForId(highMaturityRelicId);
        PositionInfo memory sellerPositionBefore = reliquary.getPositionForId(sellerRelicId);

        // Approve the relic
        vm.prank(buyer);
        reliquary.approve(address(maBeetsBoost), highMaturityRelicId);
        vm.prank(buyer);
        lpToken.approve(address(maBeetsBoost), type(uint256).max);

        // Record balances before
        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Accept the offer
        vm.prank(buyer);
        uint256 newBuyerRelicId = maBeetsBoost.acceptOffer(sellerRelicId, highMaturityRelicId, MAX_MATURED_LEVEL);

        // Verify minimal fee was collected (one level difference * fee per level)
        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);
        uint256 feeCollected = finalFeeRecipientBalance - initialFeeRecipientBalance;
        uint256 expectedTotalFee = (highMaturityPosition.amount * FEE_PER_LEVEL_BIPS) / 10000; // only one level diff
        uint256 expectedProtocolFee = (expectedTotalFee * PROTOCOL_FEE_BIPS) / 10000;

        assertTrue(
            sellerPositionBefore.level - 1 == highMaturityPosition.level,
            "Buyer's relic should be one level lower than max maturity"
        );

        PositionInfo memory newPosition = reliquary.getPositionForId(newBuyerRelicId);
        PositionInfo memory sellerPositionAfter = reliquary.getPositionForId(sellerRelicId);

        assertEq(newPosition.level, levelInfo.requiredMaturities.length - 1, "New relic should be at max maturity");
        assertEq(
            sellerPositionAfter.amount,
            sellerPositionBefore.amount + expectedTotalFee - expectedProtocolFee,
            "Seller relic size should match expected amount"
        );
        assertEq(feeCollected, expectedProtocolFee, "Protocol fee should match expected amount");
    }

    function testAcceptOfferOfferNotActive() public {
        // Create an offer
        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(sellerRelicId);

        // Cancel the offer to make it inactive
        vm.prank(seller);
        maBeetsBoost.cancelOffer(sellerRelicId);

        // Try to accept an inactive offer
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.OfferNotActive.selector));
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    function testAcceptOfferSellerNoLongerOwnsRelic() public {
        // Create an offer
        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(sellerRelicId);

        // Transfer the seller's relic to someone else
        vm.prank(seller);
        reliquary.transferFrom(seller, user1, sellerRelicId);

        // Try to accept an offer where seller no longer owns the relic
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.NotRelicOwner.selector));
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    function testAcceptOfferSellerRelicNotApproved() public {
        // Create an offer
        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(sellerRelicId);

        // Remove approval for the seller's relic
        vm.prank(seller);
        reliquary.approve(address(0), sellerRelicId);

        // Try to accept an offer where seller's relic is not approved
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.RelicNotApproved.selector));
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    function testAcceptOfferSellerRelicNotFullyMatured() public {
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Reduce maturity by adding more tokens
        _distributeLpTokens(seller, 1000 ether);
        vm.prank(seller);
        lpToken.approve(address(reliquary), 1000 ether);
        vm.prank(seller);
        reliquary.deposit(1000 ether, sellerRelicId);

        // Try to accept the offer with a seller relic that's no longer fully matured
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.RelicNotFullyMatured.selector));
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    function testAcceptOfferSellerRelicTooSmall() public {
        // Create an offer
        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(sellerRelicId);

        // Make the seller's relic too small
        PositionInfo memory position = reliquary.getPositionForId(sellerRelicId);
        uint256 withdrawAmount = position.amount - maBeetsBoost.MIN_RELIC_SIZE() + 1;

        vm.prank(seller);
        reliquary.withdraw(withdrawAmount, sellerRelicId);

        // Try to accept an offer where the seller's relic is too small
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.RelicTooSmall.selector));
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    function testAcceptOfferBuyerDoesNotOwnRelic() public {
        // Create an offer
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Transfer the buyer's relic to someone else
        vm.prank(buyer);
        reliquary.transferFrom(buyer, user1, buyerRelicId);

        // Try to accept an offer when the buyer doesn't own the relic anymore
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.NotRelicOwner.selector));
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    function testAcceptOfferBuyerRelicNotApproved() public {
        // Create an offer
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Remove approval for the buyer's relic
        vm.prank(buyer);
        reliquary.approve(address(0), buyerRelicId);

        // Try to accept an offer when the buyer's relic is not approved
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.RelicNotApproved.selector));
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    /*  function testAcceptOfferBuyerRelicFullyMatured() public {
        // Create an offer
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // Make the buyer's relic fully matured
        vm.warp(block.timestamp + timeForMaxMaturity);
        reliquary.updatePosition(buyerRelicId);

        // Try to accept an offer with a fully matured buyer relic
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.BuyerRelicFullyMatured.selector));
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    } */

    function testAcceptOfferBuyerRelicTooSmall() public {
        // Create an offer
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Create a small relic for the buyer
        uint256 smallAmount = maBeetsBoost.MIN_RELIC_SIZE() - 1;
        uint256 smallBuyerRelicId = _createRelic(buyer, smallAmount);

        // Ensure it has some maturity but not full
        vm.warp(block.timestamp + 1 days);
        reliquary.updatePosition(smallBuyerRelicId);

        // Try to accept an offer with a relic that's too small
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.RelicTooSmall.selector));
        maBeetsBoost.acceptOffer(sellerRelicId, smallBuyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    // Test the canRelicBeBoosted function with a boostable relic
    function testCanRelicBeBoosted() public {
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Test if the buyer's relic can be boosted to max level
        bool canBoost = maBeetsBoost.canRelicBeBoosted(sellerRelicId, buyerRelicId, MAX_MATURED_LEVEL);
        assertTrue(canBoost, "Buyer's relic should be boostable to max level");
    }

    // Test the canRelicBeBoosted function with a relic that can't be boosted
    function testCanRelicBeBoostedFalse() public {
        // Create a very large buyer relic that would require more tokens from the seller than available
        uint256 largeBuyerRelicId = _createRelic(buyer, 2000 ether); // Much larger than seller's relic

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Test if the large buyer relic can be boosted to max level
        bool canBoost = maBeetsBoost.canRelicBeBoosted(sellerRelicId, largeBuyerRelicId, MAX_MATURED_LEVEL);
        assertFalse(canBoost, "Large buyer relic should not be boostable");
    }

    // Test the canRelicBeBoosted function with different boost levels
    function testCanRelicBeBoostedPartialLevels() public {
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Get the current level of the buyer's relic
        PositionInfo memory buyerPosition = reliquary.getPositionForId(buyerRelicId);
        uint256 currentLevel = buyerPosition.level;

        // Test boosting just one level higher
        uint256 oneHigherLevel = currentLevel + 1;
        bool canBoostOneLevel = maBeetsBoost.canRelicBeBoosted(sellerRelicId, buyerRelicId, oneHigherLevel);
        assertTrue(canBoostOneLevel, "Buyer's relic should be boostable to one level higher");

        // Test boosting to a middle level
        LevelInfo memory levelInfo = reliquary.getLevelInfo(MABEETS_POOL_ID);
        uint256 middleLevel = (currentLevel + levelInfo.requiredMaturities.length - 1) / 2;
        bool canBoostMiddleLevel = maBeetsBoost.canRelicBeBoosted(sellerRelicId, buyerRelicId, middleLevel);
        assertTrue(canBoostMiddleLevel, "Buyer's relic should be boostable to middle level");
    }

    // Test the canRelicBeBoosted function with a level that's too low
    function testCanRelicBeBoostedTooLowLevel() public {
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        // Get the current level of the buyer's relic
        PositionInfo memory buyerPosition = reliquary.getPositionForId(buyerRelicId);
        uint256 currentLevel = buyerPosition.level;

        // Test boosting to the same level (which is technically not a boost)
        bool canBoostSameLevel = maBeetsBoost.canRelicBeBoosted(sellerRelicId, buyerRelicId, currentLevel);

        assertFalse(canBoostSameLevel, "canRelicBeBoosted should return false for same level");
    }

    function testCanRelicBeBoostedMaxBoost() public {
        uint256 relicWithNoMaturity = _createRelic(buyer, 10 ether);

        bool canBoost = maBeetsBoost.canRelicBeBoosted(sellerRelicId, relicWithNoMaturity, MAX_MATURED_LEVEL);
        assertTrue(canBoost, "Small buyer relic should be boostable by large seller relic");
    }

    function testCanRelicBeBoostedNonExistentRelic() public {
        uint256 nonExistentRelicId = 9999; // Assuming this ID doesn't exist

        // This should revert when trying to get position info for a non-existent relic
        vm.expectRevert();
        maBeetsBoost.canRelicBeBoosted(sellerRelicId, nonExistentRelicId, MAX_MATURED_LEVEL);
    }

    // Test accepting an offer with a buyer relic that's too large to be boosted
    function testAcceptOfferBuyerRelicTooLargeToBeBoosted() public {
        // Create a relatively small seller relic
        uint256 smallSellerRelicId = _createRelic(seller, 50 ether);

        // Make it fully matured
        vm.warp(block.timestamp + timeForMaxMaturity);
        reliquary.updatePosition(smallSellerRelicId);

        // Create an offer for the small seller relic
        vm.prank(seller);
        maBeetsBoost.createOffer(smallSellerRelicId);

        // Create a very large buyer relic
        uint256 largeBuyerRelicId = _createRelic(buyer, 1000 ether); // Much larger than seller's relic

        // Try to accept the offer
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.BuyerRelicTooLargeToBeBoosted.selector));
        maBeetsBoost.acceptOffer(smallSellerRelicId, largeBuyerRelicId, MAX_MATURED_LEVEL);
        vm.stopPrank();
    }

    function testAcceptOfferPartialBoost() public {
        LevelInfo memory levelInfo = reliquary.getLevelInfo(MABEETS_POOL_ID);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);

        uint256 relicId = _createRelic(buyer, 100 ether);

        vm.warp(block.timestamp + levelInfo.requiredMaturities[1]);
        reliquary.updatePosition(relicId);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, relicId, 2);

        vm.warp(block.timestamp + timeForMaxMaturity);
        reliquary.updatePosition(sellerRelicId);

        relicId = _createRelic(buyer, 100 ether);
        vm.warp(block.timestamp + levelInfo.requiredMaturities[5]);
        reliquary.updatePosition(relicId);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, relicId, 8);

        vm.warp(block.timestamp + timeForMaxMaturity);
        reliquary.updatePosition(sellerRelicId);

        relicId = _createRelic(buyer, 100 ether);
        vm.warp(block.timestamp + levelInfo.requiredMaturities[2]);
        reliquary.updatePosition(relicId);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, relicId, 9);
    }
}
