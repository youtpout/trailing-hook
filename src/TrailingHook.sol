// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract TrailingHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------
    struct TrailingInfo {
        int24 startTick;
        bool isCurrency1;
        uint32 percent;
        uint256 totalAmount;
        uint256 filledAmount;
        mapping(address => uint256) userAmount;
    }

    mapping(uint256 => TrailingInfo) listTrailings;
    uint256 lastTrailing = 1;

    mapping(PoolId => mapping(uint256 => uint32[])) lastActivationByPercent;
    mapping(PoolId => uint32) lastActivation;
    mapping(PoolId => bool) active;

    mapping(PoolId => int24) public tickLowerLasts;

    mapping(PoolId => mapping(uint32 => uint256)) public trailingByPercentId0;
    mapping(PoolId => mapping(uint32 => uint256)) public trailingByPercentId1;

    mapping(PoolId => mapping(int24 => uint256)) public trailingByTicksId;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        return (BaseHook.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function addTrailing(
        PoolId poolId,
        bool isCurrency1,
        uint256 amount,
        uint32 percentStop
    ) public {
        (, int24 tickLower, , ) = StateLibrary.getSlot0(poolManager, poolId);
        uint256 lastId = isCurrency1
            ? trailingByPercentId1[poolId][percentStop]
            : trailingByPercentId0[poolId][percentStop];
        if (lastId > 0) {
            TrailingInfo storage data = listTrailings[lastId];
            if (data.filledAmount == 0) {
                data.startTick = tickLower;
                data.totalAmount += amount;
                data.userAmount[msg.sender] += amount;
            } else {
                lastTrailing++;
                data.startTick = tickLower;
                data.isCurrency1 = isCurrency1;
                data.percent = percentStop;
                data.totalAmount += amount;
                data.userAmount[msg.sender] += amount;
            }
        }
        lastActivation[poolId] = uint32(block.timestamp);

        setTickLowerLast(poolId, tickLower);
    }

    function getTickLowerLast(PoolId poolId) public view returns (int24) {
        return tickLowerLasts[poolId];
    }

    function setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function withdraw() public {}
}
