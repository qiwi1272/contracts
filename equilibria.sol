// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface IPendleMarket {
    function readState(address router)
        external
        view
        returns (
            int256 totalPt,
            int256 totalSy,
            int256 totalLp,
            address treasury,
            int256 scalarRoot,
            uint256 expiry,
            uint256 lnFeeRateRoot,
            uint256 reserveFeePercent,
            uint256 lastLnImpliedRate
        );

    function userReward(address reward, address user)
        external
        view
        returns (
            uint128 index,
            uint128 acrued
        );

   function activeBalance(address user)
        external
        view
        returns (
            uint256 balance
        );

    function rewardState(address reward)
        external
        view
        returns (
            uint128 index,
            uint128 amount
        );
}

interface IEqbRewardPool {
    function poolInfo(uint256 pid)
        external
        view
        returns (
            address market,
            address token,
            address rewardPool,
            bool shutdown
        );
}


library EqbLib {
    type Id is bytes32;
    using SafeMath for uint256;

    function estReward(address market, address reward, address user)
        public
        view
        returns (uint256 rewardDelta)
    {
        IPendleMarket Market = IPendleMarket(market);

        (uint128 index,) = Market.rewardState(reward);

        uint256 userShares = Market.activeBalance(user);

        (uint128 userIndex, uint128 userAccrued) = Market.userReward(reward, user);

        uint256 indexDelta = index - userIndex;
        uint256 accruedDelta = userShares.mul(indexDelta).div(1e18);
        rewardDelta = userAccrued + accruedDelta;
    }

    function estRewards(address[] calldata markets, address reward, address user)
        public
        view
        returns (uint256[] memory rewardDelta)
    {
        uint256 len = markets.length;
        rewardDelta = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 delta = estReward(markets[i], reward, user);
            rewardDelta[i] = delta;
        }
    }

    function getPools(address eqb, uint256[] calldata pids)
        public
        view
        returns (address[] memory markets, address[] memory tokens, address[] memory rewardPools)
    {
        uint256 len = pids.length;
        markets = new address[](len);
        tokens = new address[](len);
        rewardPools = new address[](len);

        IEqbRewardPool Eqb = IEqbRewardPool(eqb);

        for (uint256 i = 0; i < len; i++) {
            (address market, address token, address rewardPool, bool shutdown) = Eqb.poolInfo(pids[i]);
            if (!shutdown) {
                markets[i] = market;
                tokens[i] = token;
                rewardPools[i] = rewardPool;
            }
        }
    }
}
