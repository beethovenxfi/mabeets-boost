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

    // Test parameters
    uint256 private constant PROTOCOL_FEE_BIPS = 1000; // 10%
    uint256 private constant FEE_PER_LEVEL_BIPS = 50; // 0.5% per level

    // Sonic blockchain specific constants
    string private SONIC_RPC_URL = vm.envString("SONIC_RPC_URL");
    address private RELIQUARY_ADDRESS = 0x973670ce19594F857A7cD85EE834c7a74a941684; // Replace with actual address
    uint256 private POOL_ID = 0; // Replace with a real pool ID that exists on Sonic's Reliquary

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
    }

    function _setupSellerWithMaturedRelic() private {
        uint256 amountToTransfer = 1000 ether;

        _distributeLpTokens(seller, amountToTransfer);

        // Now use the seller account to create and mature a relic
        vm.startPrank(seller);

        // Approve LP tokens for reliquary
        lpToken.approve(address(reliquary), amountToTransfer);

        // Create a relic for the seller
        uint256 relicId = reliquary.createRelicAndDeposit(seller, POOL_ID, 100 ether);

        // We need to manipulate time to make it mature
        // First save the current block timestamp
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
        // Similar approach for buyer, but we'll make it partially matured
        uint256 amountToTransfer = 1000 ether;
        _distributeLpTokens(buyer, amountToTransfer);

        vm.startPrank(buyer);

        // Approve LP tokens for reliquary
        lpToken.approve(address(reliquary), amountToTransfer);

        // Create a relic for the buyer
        uint256 relicId = reliquary.createRelicAndDeposit(buyer, POOL_ID, 50 ether);

        // Get the level info to determine intermediate maturity time
        LevelInfo memory levelInfo = reliquary.getLevelInfo(POOL_ID);
        uint256 partialMaturity = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length / 2]; // Pick middle level

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

    function _distributeLpTokens(address to, uint256 amount) internal {
        vm.startPrank(BEETS_TREASURY);
        lpToken.transfer(to, amount);
        vm.stopPrank();
    }

    // Helper function to find an existing LP token holder on the fork
    function _findLpTokenHolder() internal view returns (address) {
        // This would ideally query a known holder or use a blockchain explorer API
        // For simplicity, let's return a hardcoded address that we know holds LP tokens
        return address(0x5555555555555555555555555555555555555555); // Replace with actual holder address
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

    // Test accepting an offer
    function testAcceptOffer() public {
        // Create an offer first
        uint256 sellerRelicId = reliquary.tokenOfOwnerByIndex(seller, 0);
        uint256 buyerRelicId = reliquary.tokenOfOwnerByIndex(buyer, 0);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId, FEE_PER_LEVEL_BIPS);

        // Record initial balances
        uint256 initialBuyerLpBalance = lpToken.balanceOf(buyer);
        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        // Accept the offer
        vm.prank(buyer);
        console.log("before acceptOffer");
        maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId);
        console.log("after acceptOffer");

        // Verify LP tokens were transferred correctly
        uint256 finalBuyerLpBalance = lpToken.balanceOf(buyer);
        uint256 finalFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        assertTrue(finalBuyerLpBalance < initialBuyerLpBalance, "Buyer should have paid fees");
        assertTrue(finalFeeRecipientBalance > initialFeeRecipientBalance, "Fee recipient should have received fees");

        // Verify the relic's maturity was boosted
        PositionInfo memory position = reliquary.getPositionForId(buyerRelicId);
        // Further verification would depend on the exact implementation details
    }

    // Additional tests would follow a similar pattern...
}
