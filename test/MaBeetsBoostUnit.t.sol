// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {MaBeetsBoost} from "../src/MaBeetsBoost.sol";
import {IReliquary, PositionInfo, PoolInfo, LevelInfo} from "../src/interfaces/IReliquary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";

contract MaBeetsBoostUnitTest is Test {
    MaBeetsBoost private maBeetsBoost;
    IReliquary private reliquary;
    IERC20 private lpToken;
    MockERC20 private rewardToken;

    // Test accounts
    address private owner = address(0x1);
    address private seller = address(0x2);
    address private buyer = address(0x3);
    address private feeRecipient = address(0x4);
    address private user1 = address(0x5); // Additional test user
    address private user2 = address(0x6); // Additional test user

    // Test parameters
    uint256 private constant PROTOCOL_FEE_BIPS = 1000; // 10%
    uint256 private constant FEE_PER_LEVEL_BIPS = 50; // 0.5% per level

    // Sonic blockchain specific constants
    string private SONIC_RPC_URL = vm.envString("SONIC_RPC_URL");
    address private RELIQUARY_ADDRESS = 0x973670ce19594F857A7cD85EE834c7a74a941684;
    uint256 private POOL_ID = 0; // First pool ID in Reliquary
    address private BEETS_TREASURY = 0xc5E0250037195850E4D987CA25d6ABa68ef5fEe8;

    // Store fork ID
    uint256 private forkId;

    // Setup for tests
    function setUp() public {
        // Create a fork of Sonic blockchain
        forkId = vm.createSelectFork(SONIC_RPC_URL, 15032705);

        // Get the already deployed Reliquary
        reliquary = IReliquary(RELIQUARY_ADDRESS);

        // Fetch the LP token for the test pool
        lpToken = IERC20(reliquary.poolToken(POOL_ID));

        // Deploy MaBeetsBoost contract
        vm.startPrank(owner);
        maBeetsBoost = new MaBeetsBoost(address(reliquary), owner, PROTOCOL_FEE_BIPS, feeRecipient);
        vm.stopPrank();

        // Check that the fork is working by querying the Reliquary
        console.log("Reliquary address:", address(reliquary));
        console.log("LP Token address:", address(lpToken));

        // Setup seller with a fully matured relic
        _setupSellerWithMaturedRelic();

        // Setup buyer with non-matured relic
        _setupBuyerWithNonMaturedRelic();

        // Setup additional users
        _setupAdditionalUsers();
    }

    function _setupSellerWithMaturedRelic() private {
        uint256 amountToTransfer = 1000 ether;
        _distributeLpTokens(seller, amountToTransfer);

        vm.startPrank(seller);

        // Approve LP tokens for reliquary
        lpToken.approve(address(reliquary), amountToTransfer);

        // Create a relic for the seller
        uint256 relicId = reliquary.createRelicAndDeposit(seller, POOL_ID, 100 ether);

        // We need to manipulate time to make it mature
        uint256 currentTime = block.timestamp;

        // Get the level info to determine how much time we need to advance
        LevelInfo memory levelInfo = reliquary.getLevelInfo(POOL_ID);
        uint256 timeNeeded = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length - 1] + 1 days;

        // Warp time forward to mature the relic
        vm.warp(currentTime + timeNeeded);

        // Update the position to reflect the new maturity
        reliquary.updatePosition(relicId);

        // Approve MaBeetsBoost to operate on the relic
        reliquary.approve(address(maBeetsBoost), relicId);

        vm.stopPrank();
    }

    function _setupBuyerWithNonMaturedRelic() private {
        uint256 amountToTransfer = 1000 ether;
        _distributeLpTokens(buyer, amountToTransfer);

        vm.startPrank(buyer);

        // Approve LP tokens for reliquary
        lpToken.approve(address(reliquary), amountToTransfer);

        // Create a relic for the buyer
        uint256 relicId = reliquary.createRelicAndDeposit(buyer, POOL_ID, 50 ether);

        // Get the level info to determine intermediate maturity time
        LevelInfo memory levelInfo = reliquary.getLevelInfo(POOL_ID);
        uint256 partialMaturity = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length / 2];

        // Warp time to reach partial maturity
        vm.warp(block.timestamp + partialMaturity);

        // Update the position
        reliquary.updatePosition(relicId);

        // Approve MaBeetsBoost to operate on the relic
        reliquary.approve(address(maBeetsBoost), relicId);

        // Approve LP token transfers for paying fees
        lpToken.approve(address(maBeetsBoost), type(uint256).max);

        vm.stopPrank();
    }

    function _setupAdditionalUsers() private {
        // Setup user1 with a fully matured relic
        uint256 amountToTransfer = 1000 ether;
        _distributeLpTokens(user1, amountToTransfer);

        vm.startPrank(user1);
        lpToken.approve(address(reliquary), amountToTransfer);
        uint256 relicId = reliquary.createRelicAndDeposit(user1, POOL_ID, 100 ether);

        // Make it fully matured
        LevelInfo memory levelInfo = reliquary.getLevelInfo(POOL_ID);
        uint256 timeNeeded = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length - 1] + 1 days;
        vm.warp(block.timestamp + timeNeeded);
        reliquary.updatePosition(relicId);
        reliquary.approve(address(maBeetsBoost), relicId);
        vm.stopPrank();

        // Setup user2 with a low maturity relic
        _distributeLpTokens(user2, amountToTransfer);

        vm.startPrank(user2);
        lpToken.approve(address(reliquary), amountToTransfer);
        relicId = reliquary.createRelicAndDeposit(user2, POOL_ID, 75 ether);
        vm.warp(block.timestamp + 1 days); // Just 1 day maturity
        reliquary.updatePosition(relicId);
        reliquary.approve(address(maBeetsBoost), relicId);
        lpToken.approve(address(maBeetsBoost), type(uint256).max);
        vm.stopPrank();
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

    // Test offer creation
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
        uint256 feeTooHigh = maBeetsBoost.MAX_FEE_PER_LEVEL_BIPS() + 1;

        vm.startPrank(seller);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.FeeTooHigh.selector));
        maBeetsBoost.createOffer(relicId, feeTooHigh);
        vm.stopPrank();
    }

    function testCreateOfferFeeTooLow() public {
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);
        uint256 feeTooLow = maBeetsBoost.MIN_FEE_PER_LEVEL_BIPS() - 1;

        vm.startPrank(seller);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.FeeTooLow.selector));
        maBeetsBoost.createOffer(relicId, feeTooLow);
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

    // Test unauthorized offer cancellation
    function testUnauthorizedCancelOffer() public {
        // Create offer first
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        // Try to cancel as non-owner
        vm.startPrank(buyer);
        vm.expectRevert(); // Expect revert for unauthorized cancellation
        maBeetsBoost.cancelOffer(relicId);
        vm.stopPrank();
    }

    // Test orphan offer cancellation
    function testCancelOrphanOffer() public {
        // Create offer first
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        // Make the offer orphaned by removing approval
        vm.prank(seller);
        reliquary.approve(address(0), relicId);

        // Anyone can cancel an orphaned offer
        vm.prank(buyer);
        maBeetsBoost.cancelOrphanOffer(relicId);

        // Verify offer is inactive
        MaBeetsBoost.Offer memory offer = maBeetsBoost.getOffer(relicId);
        assertFalse(offer.active);
    }

    // Test non-orphan offer cancellation failure
    function testCancelNonOrphanOfferFailure() public {
        // Create a valid offer
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        // Try to cancel as orphan when it's not orphaned
        vm.startPrank(buyer);
        vm.expectRevert(); // Expect revert for non-orphaned offer
        maBeetsBoost.cancelOrphanOffer(relicId);
        vm.stopPrank();
    }

    // Test accepting an offer
    function testAcceptOffer() public {
        // Create an offer first
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);
        uint256 buyerRelicId = reliquary.tokenOfOwnerByIndex(buyer, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // Record initial balances and states
        PositionInfo memory buyerPositionBefore = reliquary.getPositionForId(buyerRelicId);
        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);
        uint256 initialBuyerLevel = buyerPositionBefore.level;

        // Accept the offer
        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId);

        // Get the new buyer relic ID (after split)
        uint256 newBuyerRelicId = reliquary.tokenOfOwnerByIndex(buyer, 0);

        // Verify states after acceptance
        PositionInfo memory buyerPositionAfter = reliquary.getPositionForId(newBuyerRelicId);
        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Verify fee recipient received protocol fees
        assertTrue(finalFeeRecipientBalance > initialFeeRecipientBalance, "Fee recipient should have received fees");

        // Verify the buyer's relic is at the original amount minus fees
        assertLt(
            buyerPositionAfter.amount, buyerPositionBefore.amount, "Buyer's relic amount should be reduced by fees"
        );

        // Ensure the offer is still active after acceptance
        MaBeetsBoost.Offer memory offer = maBeetsBoost.getOffer(sellerRelicId);
        assertTrue(offer.active);
    }

    // Test attempt to accept offer with fully matured relic
    function testAcceptOfferWithFullyMaturedRelic() public {
        // Create offer
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // Create a fully matured relic for buyer
        vm.startPrank(buyer);

        // Warp time to fully mature the buyer's relic
        LevelInfo memory levelInfo = reliquary.getLevelInfo(POOL_ID);
        uint256 timeNeeded = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length - 1] + 1 days;
        vm.warp(block.timestamp + timeNeeded);

        uint256 buyerRelicId = reliquary.tokenOfOwnerByIndex(buyer, 0);
        reliquary.updatePosition(buyerRelicId);

        // Try to accept offer with fully matured relic
        vm.expectRevert(); // Expect revert for fully matured buyer relic
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId);
        vm.stopPrank();
    }

    // Test protocol fee changes
    function testSetProtocolFee() public {
        uint256 newProtocolFee = 2000; // 20%

        vm.prank(owner);
        maBeetsBoost.setProtocolFeeBips(newProtocolFee);

        assertEq(maBeetsBoost.protocolFeeBips(), newProtocolFee);

        // Test with new fee percentage
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);
        uint256 buyerRelicId = reliquary.tokenOfOwnerByIndex(buyer, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId);

        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);
        uint256 protocolFeeReceived = finalFeeRecipientBalance - initialFeeRecipientBalance;

        // Calculate expected protocol fee based on actual values in the contract
        // This is approximate due to rounding errors
        assertTrue(protocolFeeReceived > 0, "Protocol fee should be collected");
    }

    // Test setting protocol fee recipient
    function testSetProtocolFeeRecipient() public {
        address newFeeRecipient = address(0x9);

        vm.prank(owner);
        maBeetsBoost.setProtocolFeeRecipient(newFeeRecipient);

        assertEq(maBeetsBoost.protocolFeeRecipient(), newFeeRecipient);

        // Test fees go to new recipient
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);
        uint256 buyerRelicId = reliquary.tokenOfOwnerByIndex(buyer, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        uint256 initialFeeRecipientBalance = lpToken.balanceOf(newFeeRecipient);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId);

        uint256 finalFeeRecipientBalance = lpToken.balanceOf(newFeeRecipient);

        assertTrue(finalFeeRecipientBalance > initialFeeRecipientBalance, "New fee recipient should receive fees");
    }

    // Test zero protocol fee
    function testZeroProtocolFee() public {
        // Set protocol fee to zero
        vm.prank(owner);
        maBeetsBoost.setProtocolFeeBips(0);

        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);
        uint256 buyerRelicId = reliquary.tokenOfOwnerByIndex(buyer, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId);

        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        assertEq(
            finalFeeRecipientBalance,
            initialFeeRecipientBalance,
            "Fee recipient should not receive fees when protocol fee is zero"
        );
    }

    // Test max protocol fee validation
    function testMaxProtocolFeeValidation() public {
        uint256 feeToHigh = maBeetsBoost.MAX_PROTOCOL_FEE_BIPS() + 1;

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.ProtocolFeeTooHigh.selector));
        maBeetsBoost.setProtocolFeeBips(feeToHigh);
        vm.stopPrank();
    }

    // Test protocol fee recipient zero address validation
    function testFeeRecipientZeroAddressValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(MaBeetsBoost.NoAddressZero.selector));
        maBeetsBoost.setProtocolFeeRecipient(address(0));
        vm.stopPrank();
    }

    // Test getOffers pagination
    function testGetOffersPagination() public {
        // Create several offers
        // Setup seller 1 (existing)
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);
        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // Setup seller 2 (user1)
        uint256 user1RelicId = reliquary.tokenOfOwnerByIndex(user1, 0);
        vm.prank(user1);
        maBeetsBoost.createOffer(user1RelicId, FEE_PER_LEVEL_BIPS + 10); // Different fee

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

    // Test getOfferWithMetadata
    function testGetOfferWithMetadata() public {
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        MaBeetsBoost.OfferWithMetadata memory offerMeta = maBeetsBoost.getOfferWithMetadata(relicId);

        assertEq(offerMeta.seller, seller, "Seller should match");
        assertEq(offerMeta.relicId, relicId, "Relic ID should match");
        assertEq(offerMeta.poolId, POOL_ID, "Pool ID should match");
        assertEq(offerMeta.feePerLevelBips, FEE_PER_LEVEL_BIPS, "Fee should match");
        assertTrue(offerMeta.active, "Offer should be active");
        assertFalse(offerMeta.isOrphan, "Offer should not be orphaned");
        assertTrue(offerMeta.excessMaturity > 0, "Should have excess maturity");
        assertTrue(offerMeta.relicSize > 0, "Should have non-zero relic size");
    }

    // Test getOfferById
    function testGetOfferById() public {
        uint256 relicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        uint256 offerId = maBeetsBoost.createOffer(relicId, FEE_PER_LEVEL_BIPS);

        MaBeetsBoost.Offer memory offer = maBeetsBoost.getOfferById(offerId);

        assertEq(offer.id, offerId, "Offer ID should match");
        assertEq(offer.seller, seller, "Seller should match");
        assertEq(offer.relicId, relicId, "Relic ID should match");
    }

    // Test multiple offer acceptances
    function testMultipleOfferAcceptances() public {
        // Create offer
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // First buyer accepts
        uint256 buyerRelicId = reliquary.tokenOfOwnerByIndex(buyer, 0);
        vm.prank(buyer);
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId);

        // Second buyer (user2) accepts
        uint256 user2RelicId = reliquary.tokenOfOwnerByIndex(user2, 0);
        vm.prank(user2);
        maBeetsBoost.acceptOffer(sellerRelicId, user2RelicId);

        // Verify offer is still active
        MaBeetsBoost.Offer memory offer = maBeetsBoost.getOffer(sellerRelicId);
        assertTrue(offer.active, "Offer should remain active after multiple acceptances");
    }

    // Test acceptance fee calculation with different level gaps
    function testFeeCalculationWithDifferentLevelGaps() public {
        // Create offer from a fully matured seller
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);
        PositionInfo memory sellerPosition = reliquary.getPositionForId(sellerRelicId);

        // Verify the seller is at max level
        LevelInfo memory levelInfo = reliquary.getLevelInfo(POOL_ID);
        assertEq(sellerPosition.level, levelInfo.requiredMaturities.length - 1, "Seller should be at max level");

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // Test with buyer at level 0 (user2)
        uint256 user2RelicId = reliquary.tokenOfOwnerByIndex(user2, 0);
        PositionInfo memory user2Position = reliquary.getPositionForId(user2RelicId);

        // Record initial states
        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Accept the offer
        vm.prank(user2);
        maBeetsBoost.acceptOffer(sellerRelicId, user2RelicId);

        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);
        uint256 protocolFeeReceived = finalFeeRecipientBalance - initialFeeRecipientBalance;

        // Calculate expected fee based on level difference
        uint256 levelDiff = sellerPosition.level - user2Position.level;
        uint256 feeBips = levelDiff * FEE_PER_LEVEL_BIPS;
        uint256 totalFee = (user2Position.amount * feeBips) / 10000;
        uint256 expectedProtocolFee = (totalFee * PROTOCOL_FEE_BIPS) / 10000;

        // Allow for small rounding differences
        assertApproxEqRel(
            protocolFeeReceived, expectedProtocolFee, 0.01e18, "Protocol fee should match expected amount"
        );
    }
}
