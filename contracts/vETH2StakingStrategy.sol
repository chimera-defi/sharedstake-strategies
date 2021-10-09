// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/IUniswapV2Router01.sol";
import "../interfaces/IMasterChefV2.sol";
import "../interfaces/ICurveFi.sol";

import {
    Math
} from "@openzeppelin/contracts/math/Math.sol";
// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

// File: vETH2StakingStrategy.sol

// Deposit eth into ETH-Veth2 crv pool
// Stake LP in masterchef
// Farm and sell SGT to ETH

contract vETH2StakingStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 _poolId = 0;
    uint256 public surplusProfit = 0;
    //Initiate staking gov interface
    IMasterChefV2 public pool = IMasterChefV2(0x84B7644095d9a8BFDD2e5bfD8e41740bc1f4f412);
    address public activeDex;



    address public constant weth        = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant sgt         = 0x24C19F7101c1731b85F1127EaA0407732E36EcDD;
    address public constant sushiRouter = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    uint constant public DENOMINATOR = 10000;
    uint public threshold = 6000;
    uint public slip = 50;
    uint public maxAmount = 1e20;
    uint public interval = 6 hours;
    uint public tank;
    uint public p;
    uint public tip;
    uint public rip;
    uint public checkpoint;


    constructor(address _vault) public BaseStrategy(_vault) {
        minReportDelay = 1 days;
        maxReportDelay = 3 days;
        profitFactor = 1000;
        debtThreshold = 1e20;


        want.safeApprove(address(pool), type(uint256).max);
        IERC20(sgt).approve(sushiRouter, type(uint256).max);
        activeDex = sushiRouter;
    }

    function name() external view override returns (string memory) {
        return "StrategyvEth2Staking";
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfStake() public view returns (uint256) {
        (uint256 amount, ) = pool.userInfo(_poolId, address(this));
        return amount;
    }

    function pendingReward() public view virtual returns (uint256) {
        return pool.pendingReward(_poolId, address(this));
    }

    function _selfBalanceOfTokensToSell() internal view virtual returns (uint256) {
        return IERC20(sgt).balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        //Add the vault tokens + staked tokens from 1inch governance contract
        uint256 totalSGT = _selfBalanceOfTokensToSell();
        totalSGT = totalSGT.add(pendingReward());

        uint256 totalWant = balanceOfStake().add(balanceOfStake());
        if(totalSGT > 0){
            totalWant = totalWant.add(convertSGTToWant(totalSGT));
        }

        return balanceOfWant().add(balanceOfStake()).add(pendingReward());
    }

    function _deposit(uint256 _depositAmount) internal {
        pool.deposit(_poolId, _depositAmount, address(this));
    }

    function _withdraw(uint256 _withdrawAmount) internal {
        pool.withdraw(_poolId, _withdrawAmount, address(this));
    }

    function getReward() internal virtual {
        pool.harvest(_poolId, address(this));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // We might need to return want to the vault
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }

        uint256 balanceOfWantBefore = balanceOfWant();
        getReward();
        _sell(_selfBalanceOfTokensToSell());
        _profit = balanceOfWant().sub(balanceOfWantBefore);
        _profit += surplusProfit;
        surplusProfit = 0;
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();

        if (_debtOutstanding >= _wantAvailable) {
            return;
        }

        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);

        if (toInvest > 0) {
            _deposit(toInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 balanceWant = balanceOfWant();
        uint256 balanceStaked = balanceOfStake();
        if (_amountNeeded > balanceWant) {
            // unstake needed amount
            _withdraw((Math.min(balanceStaked, _amountNeeded - balanceWant)));
        }
        // Since we might free more than needed, let's send back the min
        _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
        if (balanceOfWant() > _amountNeeded) {
            //Record surplus,after prepare return adjustposition will invest the excess
            uint256 surplus = balanceOfWant().sub(_amountNeeded);
            surplusProfit = surplusProfit.add(surplus);
        }
    }

    function ethToWant(uint256 _amount) public override view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(want);

        uint256[] memory amounts = IUniswapV2Router01(activeDex).getAmountsOut(_amount, path);

        return amounts[amounts.length - 1];
    }

    function convertSGTToWant(uint256 _amount) internal view returns (uint256) {
        bool is_weth = address(want) == weth;
        address[] memory path = new address[](is_weth ? 2 : 3);
        path[0] = address(sgt);
        if (is_weth) {
            path[1] = weth;
        } else {
            path[1] = weth;
            path[2] = address(want);
        }
        return IUniswapV2Router01(activeDex).getAmountsOut(_amount, path)[path.length - 1];
    }

    function _sell(uint256 _amount) internal {
        bool is_weth = address(want) == weth;
        address[] memory path = new address[](is_weth ? 2 : 3);
        path[0] = address(sgt);
        path[1] = weth;
        if (!is_weth) {
            path[2] = address(want);
        }
        IUniswapV2Router01(activeDex)
            .swapExactTokensForTokens(_amount,
                0,
                path,
                address(this),
            now);
    }

    function liquidateAllPositions() internal virtual override returns (uint256 _amountFreed) {
        // pre-harvest to get rewards
        pool.withdrawAndHarvest(_poolId, balanceOfStake(), address(this));
        getReward();
        _sell(_selfBalanceOfTokensToSell());
        uint256 balanceWant = balanceOfWant();
        liquidatePosition(balanceOfWant());
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal virtual override {
        //This claims rewards and withdraws deposited tokens
        pool.withdrawAndHarvest(_poolId, balanceOfStake(), address(this));
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    function protectedTokens() internal view override returns (address[] memory) {}
}
