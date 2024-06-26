// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ERC6909} from "v4-core/src/ERC6909.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import "forge-std/Test.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @notice This hook can execute trailing stop orders between 1 and 10%, with a step of 1.
/// Larger values limit the interest of such a hook and avoid having to manage too many data, which would be gas-consuming.
/// Based on https://github.com/saucepoint/v4-stoploss/blob/881a13ac3451b0cdab0e19e122e889f1607520b7/src/StopLoss.sol#L17
contract TrailingStopHook is BaseHook, ERC6909, Test {
    using FixedPointMathLib for uint256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    error IncorrectTickSpacing(int24 tickSpacing);
    error IncorrectPercentage(uint24 percent);
    error AlreadyExecuted(uint256 trailingId);
    error NotExecuted(uint256 trailingId);
    error NoAmount(uint256 tokenId);

    event AddTrailing(
        address indexed sender,
        uint256 indexed tokenId,
        uint256 amount,
        TrailingInfo trailingAdded
    );

    event CancelTrailing(
        address indexed sender,
        uint256 indexed tokenId,
        uint256 amount
    );

    event ClaimTrailing(
        address indexed sender,
        uint256 indexed tokenId,
        uint256 amountDeposited,
        uint256 amountOut
    );

    bytes constant ZERO_BYTES = new bytes(0);

    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => uint256 amount)))
        public trailingPositions;
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => uint256[])))
        public trailingByTicksId;
    mapping(PoolId => mapping(uint24 percent => mapping(bool zeroForOne => uint256[])))
        public trailingByPercentActive;

    // -- ERC6909 state -- //
    uint256 public lastTokenId = 0;
    mapping(uint256 tokenId => TrailingInfo) public trailingInfoById;

    struct TrailingInfo {
        PoolKey poolKey;
        int24 tickLower;
        // same basis as fees 10_000 = 1%
        uint24 percent;
        bool zeroForOne;
        uint256 totalAmount;
        uint256 filledAmount;
        // if this trailing is merged to an other
        uint256 newId;
    }

    // constants for sqrtPriceLimitX96 which allow for unlimited impact
    // (trailing stop *should* market sell regardless of market depth 🥴)
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
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

    function beforeInitialize(
        address,
        PoolKey calldata poolKey,
        uint160,
        bytes calldata
    ) external override returns (bytes4) {
        // we use a tick spacing of 50 so the price movement is 0.5% a multiple of 1%.
        if (poolKey.tickSpacing != 50) {
            revert IncorrectTickSpacing(poolKey.tickSpacing);
        }
        return TrailingStopHook.beforeInitialize.selector;
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        setTickLowerLast(key.toId(), getTickLower(tick, key.tickSpacing));
        return TrailingStopHook.afterInitialize.selector;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    )
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender == address(this)) {
            // prevent from loop call
            return (
                TrailingStopHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        PoolId poolId = key.toId();
        (, int24 tickAfter, , ) = StateLibrary.getSlot0(poolManager, poolId);

        int24 lastTick = tickLowerLasts[poolId];
        int24 currentTick = getTickLower(tickAfter, key.tickSpacing);
        int24 tick = lastTick;

        if (lastTick != currentTick) {
            // we adjust trailing to the newer tick
            if (lastTick < currentTick) {
                for (; tick < currentTick; ) {
                    rebalanceTrailings(poolId, tick, currentTick);
                    unchecked {
                        tick += key.tickSpacing;
                    }
                }
            } else {
                for (; currentTick < tick; ) {
                    rebalanceTrailings(poolId, tick, currentTick);
                    unchecked {
                        tick -= key.tickSpacing;
                    }
                }
            }
            setTickLowerLast(poolId, currentTick);
        }

        return (
            TrailingStopHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        if (sender == address(this)) {
            // prevent from loop call
            return (TrailingStopHook.afterSwap.selector, 0);
        }

        int24 prevTick = tickLowerLasts[key.toId()];
        (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 currentTick = getTickLower(tick, key.tickSpacing);
        tick = prevTick;

        uint256 swapAmounts;

        // fill trailing in the opposite direction of the swap
        // avoids abuse/attack vectors
        bool stopLossZeroForOne = !params.zeroForOne;

        // TODO: test for off by one because of inequality
        if (prevTick < currentTick) {
            for (; tick < currentTick; ) {
                swapAmounts = trailingPositions[key.toId()][tick][
                    stopLossZeroForOne
                ];
                if (swapAmounts > 0) {
                    fillStopLoss(key, tick, stopLossZeroForOne, swapAmounts);
                }
                unchecked {
                    tick += key.tickSpacing;
                }
            }
        } else {
            for (; currentTick < tick; ) {
                swapAmounts = trailingPositions[key.toId()][tick][
                    stopLossZeroForOne
                ];
                if (swapAmounts > 0) {
                    fillStopLoss(key, tick, stopLossZeroForOne, swapAmounts);
                }
                unchecked {
                    tick -= key.tickSpacing;
                }
            }
        }

        return (TrailingStopHook.afterSwap.selector, 0);
    }

    function fillStopLoss(
        PoolKey calldata poolKey,
        int24 triggerTick,
        bool zeroForOne,
        uint256 swapAmount
    ) internal {
        IPoolManager.SwapParams memory stopLossSwapParams = IPoolManager
            .SwapParams({
                zeroForOne: zeroForOne,
                // negative for exact input
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: zeroForOne
                    ? MIN_PRICE_LIMIT
                    : MAX_PRICE_LIMIT
            });

        BalanceDelta delta = handleSwap(
            poolKey,
            stopLossSwapParams,
            address(this)
        );
        // these amount was positive or they are a mistake somewhere
        uint256 amount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        PoolId poolId = poolKey.toId();

        uint256[] memory trailingIds = trailingByTicksId[poolId][triggerTick][
            zeroForOne
        ];

        for (uint i = 0; i < trailingIds.length; i++) {
            uint256 trailingId = trailingIds[i];
            TrailingInfo storage trailing = trailingInfoById[trailingId];
            // filled amount = amount out * balance trailing / amount in
            uint256 filledAmount = amount.mulDivDown(
                trailing.totalAmount,
                swapAmount
            );
            trailing.filledAmount += amount;

            // delete this trailing from list of active trailings
            uint256[] storage trailingActives = trailingByPercentActive[poolId][
                trailing.percent
            ][zeroForOne];

            // remove this position once is fullfilled
            for (uint j = 0; j < trailingActives.length; j++) {
                if (trailingActives[j] == trailingId) {
                    trailingActives[j] = trailingActives[
                        trailingActives.length - 1
                    ];
                    break;
                }
            }
            trailingActives.pop();
        }

        // delete informations once trailing is fullfilled
        delete trailingByTicksId[poolId][triggerTick][zeroForOne];
        delete trailingPositions[poolId][triggerTick][zeroForOne];
    }

    // -- Trailing stop User Facing Functions -- //
    function placeTrailing(
        PoolKey calldata poolKey,
        uint24 percent,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24 tickLower, uint256 tokenId) {
        // between 1 and 10%, with a step of 1
        if (percent < 10_000 || percent > 100_000 || percent % 10_000 != 0) {
            revert IncorrectPercentage(percent);
        }
        PoolId poolId = poolKey.toId();
        (, int24 tickSlot, , ) = StateLibrary.getSlot0(poolManager, poolId);
        // calculate ticklower base on percent trailing stop, 1% price movement equal 100 ticks change
        int24 tickChange = ((100 * int24(percent)) / 10_000);
        // change direction depend if it's zero for one
        int24 tickPercent = zeroForOne
            ? tickSlot - tickChange
            : tickSlot + tickChange;
        // round down according to tickSpacing
        tickLower = getTickLower(tickPercent, poolKey.tickSpacing);

        // transfer token to this contract
        address token = zeroForOne
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);

        trailingPositions[poolKey.toId()][tickLower][zeroForOne] += amountIn;

        // found corresponding trailing in existing list
        tokenId = mergeTrailing(
            poolId,
            percent,
            zeroForOne,
            amountIn,
            tickLower,
            0
        );
        if (tokenId == 0) {
            // if we don't find similar trailing we will create a new one
            TrailingInfo memory data = TrailingInfo(
                poolKey,
                tickLower,
                percent,
                zeroForOne,
                amountIn,
                0,
                0
            );
            lastTokenId++;
            tokenId = lastTokenId;
            trailingInfoById[tokenId] = data;
            trailingByTicksId[poolId][tickLower][zeroForOne].push(tokenId);
            trailingByPercentActive[poolId][percent][zeroForOne].push(tokenId);
        }

        // mint the receipt token
        _mint(msg.sender, tokenId, amountIn);

        emit AddTrailing(
            msg.sender,
            tokenId,
            amountIn,
            trailingInfoById[tokenId]
        );
    }

    // if user want to remove a trailing
    function removeTrailing(uint256 id) external {
        uint256 balanceUser = balanceOf[msg.sender][id];
        if (balanceUser == 0) {
            // the user has nothing to withdraw
            revert NoAmount(id);
        }

        // the trailing can be merge with other trailing we need to check were amount was moved
        uint256 activeId = getActiveTrailing(id);

        TrailingInfo storage trailing = trailingInfoById[activeId];

        if (trailing.filledAmount > 0) {
            // if trailing was filled we can't cancel it
            revert AlreadyExecuted(id);
        }

        // we burn the share of the user and remove it from active trailing
        _burn(msg.sender, id, balanceUser);
        trailing.totalAmount -= balanceUser;

        PoolKey memory poolKey = trailing.poolKey;
        bool zeroForOne = trailing.zeroForOne;
        PoolId poolId = poolKey.toId();
        int24 tick = trailing.tickLower;

        // remove amount from trailing positions
        trailingPositions[poolId][tick][zeroForOne] -= balanceUser;

        // if the trailing got no amount anymore we delete it from everywhere
        if (trailing.totalAmount == 0) {
            deleteFromActive(activeId, poolId, trailing.percent, zeroForOne);
            deleteFromTicks(activeId, poolId, tick, zeroForOne);
        }

        address token = zeroForOne
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);

        // reimbourse the user
        IERC20(token).transfer(msg.sender, balanceUser);

        emit CancelTrailing(msg.sender, id, balanceUser);
    }

    /// @notice the user claim after this trailing was fulffiles
    function claim(uint256 tokenId) external {
        // checks: an amount to redeem
        uint256 receiptBalance = balanceOf[msg.sender][tokenId];
        if (receiptBalance == 0) {
            // the user has nothing to withdraw
            revert NoAmount(tokenId);
        }
        uint256 activeId = getActiveTrailing(tokenId);
        TrailingInfo memory data = trailingInfoById[activeId];

        if (data.filledAmount == 0) {
            revert NotExecuted(tokenId);
        }

        address token = data.zeroForOne
            ? Currency.unwrap(data.poolKey.currency1)
            : Currency.unwrap(data.poolKey.currency0);

        // effects: burn the token
        // amountOut = user balance * filledAmount / total amount
        uint256 amountOut = receiptBalance.mulDivDown(
            data.filledAmount,
            data.totalAmount
        );

        _burn(msg.sender, tokenId, receiptBalance);

        // interaction: transfer the underlying to the caller
        IERC20(token).transfer(msg.sender, amountOut);

        emit ClaimTrailing(msg.sender, tokenId, receiptBalance, amountOut);
    }

    // ---------- //

    // -- Util functions -- //
    function getActiveTrailing(uint256 id) public view returns (uint256) {
        TrailingInfo memory trailing = trailingInfoById[id];
        if (trailing.newId != 0 && trailing.newId != id) {
            return getActiveTrailing(trailing.newId);
        }
        return id;
    }

    function countActiveTrailingByPercent(
        PoolId poolId,
        uint24 percent,
        bool zeroForOne
    ) public view returns (uint256) {
        return trailingByPercentActive[poolId][percent][zeroForOne].length;
    }

    function countTrailingByTicks(
        PoolId poolId,
        int24 tick,
        bool zeroForOne
    ) public view returns (uint256) {
        return trailingByTicksId[poolId][tick][zeroForOne].length;
    }

    /// @notice Try to find a trailing who match the trailing pass in parameters
    /// the goal is to reunite trailing of same percentage on the same ticks
    /// so we will manage less trailing in each operations
    /// return 0 if don't find matching trailing
    function mergeTrailing(
        PoolId poolId,
        uint24 percent,
        bool zeroForOne,
        uint256 amount,
        int24 newTick,
        uint256 trailingId
    ) private returns (uint256) {
        uint256[] storage trailingActives = trailingByPercentActive[poolId][
            percent
        ][zeroForOne];
        for (uint i = 0; i < trailingActives.length; i++) {
            uint256 id = trailingActives[i];
            if (trailingId != id) {
                TrailingInfo storage trailing = trailingInfoById[id];
                if (trailing.tickLower == newTick) {
                    // merge amount of the trailings
                    trailing.totalAmount += amount;
                    return id;
                }
            }
        }
        return 0;
    }

    /// @notice Trailing need to follow actual price
    /// so we readjust them between tick change
    /// if tick grow we update trailing based on currency 0
    /// if the tick decrease we update trailing based on currency 1
    function rebalanceTrailings(
        PoolId poolId,
        int24 lastTick,
        int24 newTick
    ) private {
        bool zeroForOne = newTick > lastTick;
        for (uint i = 1; i < 10; i++) {
            uint24 percent = uint24(i) * 10_000;
            // todo don't move all percentage
            uint256[] memory activeTrailings = trailingByPercentActive[poolId][
                percent
            ][zeroForOne];

            for (uint j = 0; j < activeTrailings.length; j++) {
                // calcul tick lower by percent
                // calculate ticklower base on percent trailing stop, 1% price movement equal 100 ticks change
                int24 tickChange = ((100 * int24(percent)) / 10_000);
                // change direction depend if it's zero for one
                int24 tickLower = zeroForOne
                    ? newTick - tickChange
                    : newTick + tickChange;
                uint256 trailingId = activeTrailings[j];
                TrailingInfo storage trailing = trailingInfoById[trailingId];
                int24 oldTick = trailing.tickLower;
                // move amount from  trailingPositions
                trailingPositions[poolId][oldTick][zeroForOne] -= trailing
                    .totalAmount;
                trailingPositions[poolId][tickLower][zeroForOne] += trailing
                    .totalAmount;

                // update trailing by tick id too
                deleteFromTicks(trailingId, poolId, oldTick, zeroForOne);
                // try to merge it
                uint256 mergeId = mergeTrailing(
                    poolId,
                    percent,
                    zeroForOne,
                    trailing.totalAmount,
                    tickLower,
                    trailingId
                );

                if (mergeId == 0) {
                    trailingByTicksId[poolId][tickLower][zeroForOne].push(
                        trailingId
                    );

                    // update tick in current trailing if not merged
                    trailing.tickLower = tickLower;
                } else {
                    trailing.newId = mergeId;
                    // delete from active if the trailing was merged
                    deleteFromActive(trailingId, poolId, percent, zeroForOne);
                }
            }
        }
    }

    function handleSwap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        address sender
    ) private returns (BalanceDelta delta) {
        delta = poolManager.swap(key, params, ZERO_BYTES);
        //return delta;

        if (params.zeroForOne) {
            if (delta.amount0() < 0) {
                if (key.currency0.isNative()) {
                    poolManager.settle{value: uint128(-delta.amount0())}(
                        key.currency0
                    );
                } else {
                    IERC20Minimal(Currency.unwrap(key.currency0)).transfer(
                        address(poolManager),
                        uint128(-delta.amount0())
                    );
                    poolManager.settle(key.currency0);
                }
            }
            if (delta.amount1() > 0) {
                poolManager.take(
                    key.currency1,
                    sender,
                    uint128(delta.amount1())
                );
            }
        } else {
            if (delta.amount1() < 0) {
                if (key.currency1.isNative()) {
                    poolManager.settle{value: uint128(-delta.amount1())}(
                        key.currency1
                    );
                } else {
                    IERC20Minimal(Currency.unwrap(key.currency1)).transfer(
                        address(poolManager),
                        uint128(-delta.amount1())
                    );
                    poolManager.settle(key.currency1);
                }
            }
            if (delta.amount0() > 0) {
                poolManager.take(
                    key.currency0,
                    sender,
                    uint128(delta.amount0())
                );
            }
        }
    }

    function setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getTickLower(
        int24 tick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }

    // -- delete a trailing from all active list-- //

    function deleteFromActive(
        uint256 idToDelete,
        PoolId poolId,
        uint24 percent,
        bool zeroForOne
    ) private {
        uint256[] storage arr = trailingByPercentActive[poolId][percent][
            zeroForOne
        ];
        // Move the last element into the place to delete
        for (uint j = 0; j < arr.length; j++) {
            if (arr[j] == idToDelete) {
                arr[j] = arr[arr.length - 1];
                break;
            }
        }
        // Remove the last element
        arr.pop();
    }

    function deleteFromTicks(
        uint256 idToDelete,
        PoolId poolId,
        int24 tick,
        bool zeroForOne
    ) private {
        uint256[] storage arr = trailingByTicksId[poolId][tick][zeroForOne];
        // Move the last element into the place to delete
        for (uint j = 0; j < arr.length; j++) {
            if (arr[j] == idToDelete) {
                arr[j] = arr[arr.length - 1];
                break;
            }
        }
        // Remove the last element
        arr.pop();
    }
}
