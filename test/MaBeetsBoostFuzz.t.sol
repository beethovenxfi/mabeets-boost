// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {MaBeetsBoost} from "../src/MaBeetsBoost.sol";
import {IReliquary, PositionInfo, PoolInfo, LevelInfo} from "../src/interfaces/IReliquary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISonicStaking {
    function deposit() external payable returns (uint256);
}

interface IBalancerPool {
    function getPoolId() external view returns (bytes32);
}

interface IVault {
    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest memory request)
        external
        payable;

    struct JoinPoolRequest {
        address[] assets;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }
}

contract MaBeetsBoostFuzzTest is Test {
    MaBeetsBoost private maBeetsBoost;
    IReliquary private reliquary;
    IERC20 private lpToken;

    uint256 private constant MAX_MATURED_LEVEL = 10;

    // Test accounts
    address private owner = address(0x1);
    address private seller = address(0x2);
    address private buyer = address(0x3);
    address private feeRecipient = address(0x4);

    // Test parameters
    string private SONIC_RPC_URL = vm.envString("SONIC_RPC_URL");
    address private RELIQUARY_ADDRESS = 0x973670ce19594F857A7cD85EE834c7a74a941684;
    uint256 private MABEETS_POOL_ID = 0;
    address private BEETS_WHALE = 0xc5E0250037195850E4D987CA25d6ABa68ef5fEe8;
    address private STS_ADDRESS = 0xE5DA20F15420aD15DE0fa650600aFc998bbE3955;
    address private VAULT_ADDRESS = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address private BEETS_ADDRESS = 0x2D0E0814E62D80056181F5cd932274405966e4f0;

    ISonicStaking private stS;
    IVault private vault;

    uint256 timeForMaxMaturity;

    uint256 private constant BIG_NUMBER = 100_000_000_000_000 ether;

    uint256 private maxLpTokens;

    // Setup for tests
    function setUp() public {
        // Create a fork of Sonic blockchain
        vm.createSelectFork(SONIC_RPC_URL, 15032705);

        // Get the already deployed Reliquary
        reliquary = IReliquary(RELIQUARY_ADDRESS);

        // Fetch the LP token for the test pool
        lpToken = IERC20(reliquary.poolToken(MABEETS_POOL_ID));

        stS = ISonicStaking(STS_ADDRESS);
        IERC20 stsToken = IERC20(STS_ADDRESS);
        vault = IVault(VAULT_ADDRESS);
        // Deploy MaBeetsBoost contract
        vm.startPrank(owner);
        vm.deal(owner, BIG_NUMBER);

        stS.deposit{value: BIG_NUMBER - 1 ether}();

        maBeetsBoost = new MaBeetsBoost(address(reliquary), owner, 0, feeRecipient, MABEETS_POOL_ID, 10);

        address[] memory assets = new address[](2);
        assets[0] = address(BEETS_ADDRESS);
        assets[1] = address(STS_ADDRESS);
        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = type(uint256).max;
        maxAmountsIn[1] = type(uint256).max;

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = 0;
        amountsIn[1] = IERC20(STS_ADDRESS).balanceOf(owner);

        stsToken.approve(address(vault), stsToken.balanceOf(owner));

        vault.joinPool(
            IBalancerPool(address(lpToken)).getPoolId(),
            owner,
            owner,
            IVault.JoinPoolRequest({
                assets: assets,
                maxAmountsIn: maxAmountsIn,
                userData: abi.encode(1, amountsIn, 0),
                fromInternalBalance: false
            })
        );

        uint256 lpTokenBalance = lpToken.balanceOf(owner);
        maxLpTokens = lpTokenBalance / 2;

        lpToken.transfer(seller, maxLpTokens);
        lpToken.transfer(buyer, maxLpTokens);

        vm.stopPrank();

        // Get the time for max maturity
        LevelInfo memory levelInfo = reliquary.getLevelInfo(MABEETS_POOL_ID);
        timeForMaxMaturity = levelInfo.requiredMaturities[levelInfo.requiredMaturities.length - 1];
    }

    function _createRelic(address user, uint256 amount) private returns (uint256 relicId) {
        vm.startPrank(user);

        lpToken.approve(address(reliquary), amount);
        relicId = reliquary.createRelicAndDeposit(user, MABEETS_POOL_ID, amount);

        // Approve MaBeetsBoost to operate on the relic
        reliquary.approve(address(maBeetsBoost), relicId);

        vm.stopPrank();
    }

    function testAcceptOfferFuzz(
        uint256 sellerRelicSize,
        uint256 buyerRelicSize,
        uint256 feePerLevelBips,
        uint256 protocolFeeBips,
        uint256 sellerRelicMaturity,
        uint256 buyerRelicMaturity,
        uint256 boostToLevel
    ) public {
        feePerLevelBips =
            bound(feePerLevelBips, maBeetsBoost.MIN_FEE_PER_LEVEL_BIPS(), maBeetsBoost.MAX_FEE_PER_LEVEL_BIPS());
        buyerRelicSize = bound(buyerRelicSize, maBeetsBoost.MIN_RELIC_SIZE(), maxLpTokens);
        sellerRelicSize = bound(sellerRelicSize, buyerRelicSize, maxLpTokens);
        protocolFeeBips = bound(protocolFeeBips, 0, maBeetsBoost.MAX_PROTOCOL_FEE_BIPS());
        // Ensure the buyer relic is never max matured
        buyerRelicMaturity = bound(buyerRelicMaturity, 0, timeForMaxMaturity - 1);
        // We need to ensure that the seller's relic is mature enough to accept the offer
        // Assuming 10 weeks to max maturity, 10 weeks * 1,000,000 = 10,000,000 weeks = 192,307 years
        sellerRelicMaturity = bound(sellerRelicMaturity, timeForMaxMaturity * 2, timeForMaxMaturity * 1_000_000);

        vm.startPrank(owner);
        maBeetsBoost.setProtocolFeeBips(protocolFeeBips);
        maBeetsBoost.setFeePerLevelBips(feePerLevelBips);
        vm.stopPrank();

        uint256 sellerRelicId = _createRelic(seller, sellerRelicSize);
        vm.warp(sellerRelicMaturity + block.timestamp);
        reliquary.updatePosition(sellerRelicId);

        uint256 buyerRelicId = _createRelic(buyer, buyerRelicSize);
        vm.warp(buyerRelicMaturity + block.timestamp);
        reliquary.updatePosition(buyerRelicId);

        vm.prank(seller);
        maBeetsBoost.createOffer(sellerRelicId);
        vm.stopPrank();

        PositionInfo memory buyerPositionBefore = reliquary.getPositionForId(buyerRelicId);
        PositionInfo memory sellerPositionBefore = reliquary.getPositionForId(sellerRelicId);
        uint256 initialFeeRecipientBalance = lpToken.balanceOf(feeRecipient);

        boostToLevel = bound(boostToLevel, buyerPositionBefore.level + 1, MAX_MATURED_LEVEL);

        uint256 feeBips = feePerLevelBips * (boostToLevel - buyerPositionBefore.level);
        uint256 expectedTotalFeeAmount = (buyerPositionBefore.amount * feeBips) / maBeetsBoost.BIPS_DENOMINATOR();
        uint256 expectedProtocolFeeAmount = (expectedTotalFeeAmount * protocolFeeBips) / maBeetsBoost.BIPS_DENOMINATOR();
        uint256 expectedSellerFeeAmount = expectedTotalFeeAmount - expectedProtocolFeeAmount;
        uint256 expectedBuyerRelicAmount = buyerPositionBefore.amount - expectedTotalFeeAmount;

        vm.prank(buyer);
        uint256 newBuyerRelicId = maBeetsBoost.acceptOffer(sellerRelicId, buyerRelicId, boostToLevel);
        vm.stopPrank();

        // Verify the relics are owned by the correct addresses
        assertEq(reliquary.ownerOf(newBuyerRelicId), buyer);
        assertEq(reliquary.ownerOf(sellerRelicId), seller);

        PositionInfo memory buyerPositionAfter = reliquary.getPositionForId(newBuyerRelicId);
        PositionInfo memory sellerPositionAfter = reliquary.getPositionForId(sellerRelicId);

        // Verify the buyer relic is smaller
        assertTrue(buyerPositionAfter.amount < buyerPositionBefore.amount);
        // Verify the seller relic is larger
        assertTrue(sellerPositionAfter.amount > sellerPositionBefore.amount);

        // Verify the buyer relic amount is as expected
        assertEq(buyerPositionAfter.amount, expectedBuyerRelicAmount);
        // Verify the seller relic amount is as expected
        assertEq(sellerPositionAfter.amount, sellerPositionBefore.amount + expectedSellerFeeAmount);

        // Verify the fee recipient received the expected amount of protocol fees
        assertEq(lpToken.balanceOf(feeRecipient), initialFeeRecipientBalance + expectedProtocolFeeAmount);
    }
}
