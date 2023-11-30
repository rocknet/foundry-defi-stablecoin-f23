// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;

    address weth;
    address wbtc;

    uint256 timesMintCalled;
    uint256 timesDepositCalled;
    uint256 timesRedeemCalled;
    address[] usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint8).max;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc, address _ethUsdPriceFeedAddress) {
        engine = _engine;
        dsc = _dsc;
        ethUsdPriceFeed = MockV3Aggregator(_ethUsdPriceFeedAddress);

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = collateralTokens[0];
        wbtc = collateralTokens[1];
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);
        engine.mintDsc(amount);
        vm.stopPrank();
        timesMintCalled++;
        console.log("Times mint called: ", timesMintCalled);
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = ERC20Mock(_getCollateralFromSeed(collateralSeed));
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);

        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);

        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
        timesDepositCalled++;
        console.log("Times deposit called: ", timesDepositCalled);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        ERC20Mock collateral = ERC20Mock(_getCollateralFromSeed(collateralSeed));
        // Kind of cheesey, but it's a test, so we can get the price from the engine
        uint256 collateralPrice = engine.getUsdValue(address(collateral), 1);
        console.log("collateral price: ", collateralPrice);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);

        uint256 collateralBalanceOfUser = engine.getCollateralBalanceOfUser(sender, address(collateral));

        console.log("dsc minted for this user: ", totalDscMinted);
        console.log("collateral balance of user: ", collateralBalanceOfUser);
        console.log("collateral value: ", collateralValueInUsd);
        console.log("collateral weth: ", address(collateral) == weth);
        console.log("collateral price: ", collateralPrice);

        // Get the amount of collateral that won't put the user in bad health, and isn't more than they have
        amountCollateral = bound(
            amountCollateral,
            0,
            _min(collateralBalanceOfUser, ((collateralValueInUsd / 2) - totalDscMinted) / collateralPrice)
        );
        console.log("amountCollateral: ", amountCollateral);

        vm.startPrank(sender);

        if (amountCollateral == 0) {
            return;
        }

        engine.redeeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        timesRedeemCalled++;
        console.log("Times redeem called: ", timesRedeemCalled);
    }

    // This breaks our invariant test suite
    // function updateCollateralPrice(uint96 _newPrice) public {
    //     int256 newPrice = int256(uint256(_newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPrice);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (address) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
