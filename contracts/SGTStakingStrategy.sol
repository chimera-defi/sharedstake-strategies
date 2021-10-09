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

import {
    Math
} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/IMasterChefV2.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

// File: SGTStakingStrategy.sol

contract SGTStakingStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 _poolId = 4;
    uint256 public surplusProfit = 0;
    //Initiate staking gov interface
    IMasterChefV2 public pool = IMasterChefV2(0x84B7644095d9a8BFDD2e5bfD8e41740bc1f4f412);

    constructor(address _vault) public BaseStrategy(_vault) {
        //Approve staking contract to spend ALCX tokens
        want.safeApprove(address(pool), type(uint256).max);
    }

    function name() external view override returns (string memory) {
        return "StrategySGTStaking";
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

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256) {
        // This strat only deposits SGT, to farm and re-deposit SGT, similiar to AlchemixStakingStrategy which does not implement this func. 
        // https://etherscan.io/address/0x9a631F009eA64eeD2306c1FD34A7e728880a67aF#code
        return 0;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        //Add the vault tokens + staked tokens from 1inch governance contract
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

        _loss = _amountNeeded.sub(balanceOfWant());
    }

    function liquidateAllPositions() internal virtual override returns (uint256 _amountFreed) {
        // pre-harvest to get rewards
        pool.withdrawAndHarvest(_poolId, balanceOfStake(), address(this));
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
