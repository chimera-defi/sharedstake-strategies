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

// use against 0xa258C4606Ca8206D8aA700cE2143D7db854D168c eth vault
/**
gov = "ychad.eth"
evault = Vault.at("0xa258C4606Ca8206D8aA700cE2143D7db854D168c")

s = vETH2CRVStakingStrategy.deploy(evault, {"from": accounts[0]})

evault.addStrategy(s, 1000, 0, 2 ** 256 - 1, 50, {"from": gov})

harvest_tx = s.harvest({"from": accounts[0]}) 
ret1 = evault.strategies(s)
chain.mine(50)
harvest_tx = s.harvest({"from": accounts[0]}) 
ret2 = evault.strategies(s)

 */

// Stake ETH to vETH2-wETH CRV pool
// Stake CRV LP in masterchef
// Farm and sell SGT to ETH

contract vETH2CRVStakingStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 _poolId = 5;
    uint256 public surplusProfit = 0;
    uint public slip = 50;
    uint constant public DENOMINATOR = 10000;
    uint public tank;

    //Initiate staking gov interface
    IMasterChefV2 public pool = IMasterChefV2(0x84B7644095d9a8BFDD2e5bfD8e41740bc1f4f412);
    address public activeDex;

    ICurveFi public constant crvpool = ICurveFi(0xf03bD3cfE85f00bF5819AC20f0870cE8a8d1F0D8);
    IERC20 public constant vethCRV = IERC20(0xf03bD3cfE85f00bF5819AC20f0870cE8a8d1F0D8);


    address public constant weth        = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant sgt         = 0x24C19F7101c1731b85F1127EaA0407732E36EcDD;
    address public constant sushiRouter = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    // make sure sgt -> veth2 is possible 

    constructor(address _vault) public BaseStrategy(_vault) {
        //Approve staking contract to spend ALCX tokens
        // want = weth in this case, so vault needs to be a eth vault

        want.safeApprove(address(crvpool), type(uint256).max);
        vethCRV.safeApprove(address(pool), type(uint256).max);
        vethCRV.safeApprove(address(crvpool), type(uint256).max);

        IERC20(sgt).approve(sushiRouter, type(uint256).max);
        activeDex = sushiRouter;
    }

    function name() external view override returns (string memory) {
        return "StrategvEth2CRV2Staking";
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfStake() public view returns (uint256) {
        (uint256 amount, ) = pool.userInfo(_poolId, address(this));
        return amount;
    }

    function balanceOfvethCRV() public view returns (uint) {
        return vethCRV.balanceOf(address(this));
    }

    function balanceOfvethCRVinWant() public view returns (uint) {
        return balanceOfvethCRV().mul(crvpool.get_virtual_price()).div(1e18);
    }

    function balanceOfStakeInWant() public view returns (uint) {
      return balanceOfStake().mul(crvpool.get_virtual_price()).div(1e18);
    }

    function pendingReward() public view virtual returns (uint256) {
        return pool.pendingReward(_poolId, address(this));
    }

    function _selfBalanceOfTokensToSell() internal view virtual returns (uint256) {
        return IERC20(sgt).balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
      uint256 totalSGT = _selfBalanceOfTokensToSell().add(pendingReward());
      uint256 totalWant = balanceOfWant().add(balanceOfStakeInWant()).add(balanceOfvethCRVinWant());
      return totalWant.add(convertSGTToWant(totalSGT));
    }

    function _deposit(uint256 _depositAmount) public {
        pool.deposit(_poolId, _depositAmount, address(this));
    }

    function _withdraw(uint256 _withdrawAmount) internal {
        getReward();
        _sell(_selfBalanceOfTokensToSell());
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
      return _prepareReturn(_debtOutstanding);
    }

    function _prepareReturn2(uint256 _debtOutstanding)
        public
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {

        tank = balanceOfWant();
        if (_debtOutstanding > 0) {
            if (tank >= _debtOutstanding) {
                _profit = tank.sub(_debtOutstanding);
                _debtPayment = _debtOutstanding;
                tank = tank.sub(_debtOutstanding);
            } else {
                uint _withdrawn = _withdrawSome(_debtOutstanding.sub(tank));
                _withdrawn = _withdrawn.add(tank);
                if (_withdrawn < _debtOutstanding) {
                  _loss = _loss.add(_debtOutstanding.sub(_withdrawn));
                  _profit = 0;
                  _debtPayment = _debtOutstanding.sub(_withdrawn);
                  tank = 0;
                } else {
                  _profit = _profit.add(_withdrawn.sub(_debtOutstanding));
                  _loss = 0;
                  _debtPayment = _debtOutstanding;
                  tank = balanceOfWant();
                }
            }
        }
    }


    function _prepareReturn(uint256 _debtOutstanding)
        public
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {

        // We might need to return want to the vault
        if (_debtOutstanding > balanceOfWant()) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }

        uint256 balanceOfWantBefore = balanceOfWant();
        getReward();
        _sell(_selfBalanceOfTokensToSell());
        _profit = balanceOfWant().sub(balanceOfWantBefore);
        tank = balanceOfWant();

        surplusProfit = 0;
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();

        if (_debtOutstanding >= _wantAvailable) {
            return;
        }

        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);

        if (toInvest > 0) {
          deposit(toInvest);
        }
    }

    function deposit(uint256 toInvest) public {
      crvpool.add_liquidity([0,toInvest], 0);
      uint _amnt = balanceOfvethCRV();
      if (_amnt > 0) {
          _deposit(_amnt);
      }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint _balance = balanceOfWant();
        if (_balance < _amountNeeded) {
            _liquidatedAmount = _withdrawSome(_amountNeeded.sub(_balance));
            _liquidatedAmount = _liquidatedAmount.add(_balance);
            if (_liquidatedAmount > _amountNeeded) _liquidatedAmount = _amountNeeded;
            else _loss = _amountNeeded.sub(_liquidatedAmount);
            tank = 0;
        }
        else {
            _liquidatedAmount = _amountNeeded;
            if (tank >= _amountNeeded) tank = tank.sub(_amountNeeded);
            else tank = 0;
        }
    }

    function _withdrawSome(uint _amount) internal returns (uint) {
        uint _amnt = _amount.mul(1e18).div(crvpool.get_virtual_price());
        uint _before = balanceOfvethCRV();
        _withdraw((Math.min(balanceOfStake(), _amnt )));
        uint _after = balanceOfvethCRV();
        return _withdrawOne(_after.sub(_before));
    }

    function _withdrawOne(uint _amnt) internal returns (uint _bal) {
        uint _before = balanceOfWant();
        crvpool.remove_liquidity_one_coin(_amnt, 0, _amnt.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR));
        uint _after = balanceOfWant();

        _bal = _after.sub(_before);
    }


    function ethToWant(uint256 _amount) public override view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(want);

        uint256[] memory amounts = IUniswapV2Router01(activeDex).getAmountsOut(_amount, path);

        return amounts[amounts.length - 1];
    }

    function convertSGTToWant(uint256 _amount) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(sgt);
        path[1] = weth;
        return IUniswapV2Router01(activeDex).getAmountsOut(_amount, path)[path.length - 1];
    }

    function _sell(uint256 _amount) internal {
      if (_amount == 0) return;
        address[] memory path = new address[](2);
        path[0] = address(sgt);
        path[1] = weth;
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
