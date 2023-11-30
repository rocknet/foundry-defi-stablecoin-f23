// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MINT_AMOUNT = 8000e18;
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier mintedDsc() {
        vm.prank(USER);
        engine.mintDsc(MINT_AMOUNT);
        _;
    }

    /**
     * ctor tests
     */

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /**
     * Price tests
     */

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;

        assertEq(30000e18, engine.getUsdValue(weth, ethAmount));
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;

        assertEq(expectedWeth, engine.getTokenAmountFromUsd(weth, usdAmount));
    }

    /**
     * Deposit tests
     */

    function testRevertIfCollateralIsZero() public {
        vm.startPrank(USER);
        // No need to even approve since this reverts prior to attempting to transfer
        // ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfDisallowedToken() public {
        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__DisallowedToken.selector);
        engine.depositCollateral(makeAddr("fakeToken"), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepsositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        uint256 expectedDscMinted = 0;
        uint256 expectedCollateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);

        assertEq(expectedDscMinted, totalDscMinted);
        assertEq(expectedCollateralValueInUsd, collateralValueInUsd);
    }

    function testHealthFactorAfterDeposit() public depositedCollateral {
        assertEq(type(uint256).max, engine.getHealthFactor(USER));
    }

    /**
     * Mint tests
     */
    function testMint10000HappyPath() public depositedCollateral {
        vm.prank(USER);

        // Mint $10,000 worth of DSC
        engine.mintDsc(MINT_AMOUNT);

        uint256 hf = engine.getHealthFactor(USER);

        // Health factor should be 1250000000000000000 after deposit of $20k and minting $10k
        assertEq(1250000000000000000, hf);
        assertEq(MINT_AMOUNT, dsc.balanceOf(USER));
    }

    function testMintRevertsIfUnhealthy() public depositedCollateral {
        vm.prank(USER);

        // Mint $11,000 worth of DSC
        uint256 amountToMint = 11000e18;
        // 10e18 / 11e18 = 909090909090909090
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 909090909090909090));
        engine.mintDsc(amountToMint);
    }

    /**
     * Burn tests
     */
    function testDscBurned() public depositedCollateral mintedDsc {
        assertEq(MINT_AMOUNT, dsc.balanceOf(USER));

        vm.startPrank(USER);
        dsc.approve(address(engine), MINT_AMOUNT);
        engine.burnDsc(MINT_AMOUNT);

        assertEq(0, dsc.balanceOf(USER));
    }

    /**
     * Redeem tests
     */
    function testRedeeemCollateral() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        engine.redeeemCollateral(weth, 1 ether);

        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        assertEq(18000e18, collateralValueInUsd);
        assertEq(1 ether, ERC20Mock(weth).balanceOf(USER));
    }

    function testRedeeemRevertsIfUnhealthy() public depositedCollateral mintedDsc {
        vm.startPrank(USER);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 875000000000000000));
        engine.redeeemCollateral(weth, 3 ether);
    }

    /**
     * Liquidate tests
     */
    function testLiquidateRevertsIfHealthy() public depositedCollateral mintedDsc {
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, USER, 1 ether);
    }

    function testLiquidate() public depositedCollateral mintedDsc {
        // drop the price of eth, so that the user with $8000 minted DSC is now unhealthy
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(1500e8));

        address liquidator = makeAddr("liquidator");

        // Mint some dsc to the liquidator
        vm.prank(address(engine));
        dsc.mint(liquidator, 1000e18);

        console.log("Starting health factor: ", engine.getHealthFactor(USER));

        // approve dsc and liquidate 1 ether ($1500)
        vm.startPrank(liquidator);
        dsc.approve(address(engine), 1000e18);
        engine.liquidate(weth, USER, 1000e18);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        // Minted $8000 DSC, $1000 liqidated, $7000 remain
        assertEq(7000e18, totalDscMinted);

        // Because .73333 worth of weth was withdrawn, collateral is 9.266666666666667 weth, which is 13900
        assertEq(13900000000000000002000, collateralValueInUsd);

        // $1000 / 1500 = 0.6666, with bonus = 0.733333 weth should be in liquidator balance
        assertEq(733333333333333332, ERC20Mock(weth).balanceOf(liquidator));

        // liquidator should have 0 dsc left
        assertEq(0, dsc.balanceOf(liquidator));
    }

    /**
     * view tests
     */
    function testGetCollateralTokens() public {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetCollateralBalance() public depositedCollateral {
        assertEq(AMOUNT_COLLATERAL, engine.getCollateralBalanceOfUser(USER, weth));
    }
}
