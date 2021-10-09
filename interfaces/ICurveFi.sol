
   
// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// Part: ICurveFi

interface ICurveFi {
    function get_virtual_price() external view returns (uint256);
    function balances(uint256) external view returns (uint256);
    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount
    ) external payable;
    function remove_liquidity_one_coin(
        uint256 _token_amount,
        int128 i,
        uint256 min_amount
    ) external;
}
