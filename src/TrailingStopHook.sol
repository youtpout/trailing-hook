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
import {UniV4UserHook} from "./UniV4UserHook.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ERC6909} from "v4-core/src/ERC6909.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import "forge-std/Test.sol";

/// @notice This hook can execute trialing stop orders between 1 and 10%, with a step of 1.
/// Larger values limit the interest of such a hook and avoid having to manage too many data, which would be gas-consuming.
/// Based on https://github.com/saucepoint/v4-stoploss/blob/881a13ac3451b0cdab0e19e122e889f1607520b7/src/StopLoss.sol#L17
contract TrailingStopHook is UniV4UserHook, ERC6909, Test {
    using FixedPointMathLib for uint256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    error IncorrectPercentage(uint24 percent);

    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount)))
        public trailingPositions;
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => uint256[])))
        public trailingByTicksId;

    mapping(PoolId => mapping(uint24 percent => mapping(bool zeroForOne => uint256[])))
        public trailingByPercentActive;

    // -- ERC6909 state -- //
    uint256 lastTokenId;
    mapping(uint256 tokenId => TrailingInfo) tokenIdIndex;
    mapping(uint256 tokenId => bool) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public claimable;
    mapping(uint256 tokenId => uint256 supply) public totalSupply;

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
    // (stop loss *should* market sell regardless of market depth 🥴)
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    constructor(IPoolManager _poolManager) UniV4UserHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
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
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    )
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (, int24 tickAfter, , ) = StateLibrary.getSlot0(
            poolManager,
            key.toId()
        );
        int24 newTick = getTickLower(tickAfter, key.tickSpacing);
        setTickLowerLast(key.toId(), newTick);

        return (
            TrailingStopHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        int24 prevTick = tickLowerLasts[key.toId()];
        (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 currentTick = getTickLower(tick, key.tickSpacing);
        tick = prevTick;

        int256 swapAmounts;

        // todo calculate percent change
        uint24 percentChange = 1;

        // fill stop losses in the opposite direction of the swap
        // avoids abuse/attack vectors
        bool stopLossZeroForOne = !params.zeroForOne;

        // TODO: test for off by one because of inequality
        if (prevTick < currentTick) {
            for (; tick < currentTick; ) {
                swapAmounts = trailingPositions[key.toId()][tick][
                    stopLossZeroForOne
                ];
                if (swapAmounts > 0) {
                    fillStopLoss(
                        key,
                        tick,
                        percentChange,
                        stopLossZeroForOne,
                        swapAmounts
                    );
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
                    fillStopLoss(
                        key,
                        tick,
                        percentChange,
                        stopLossZeroForOne,
                        swapAmounts
                    );
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
        uint24 percent,
        bool zeroForOne,
        int256 swapAmount
    ) internal {
        IPoolManager.SwapParams memory stopLossSwapParams = IPoolManager
            .SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: swapAmount,
                sqrtPriceLimitX96: zeroForOne
                    ? MIN_PRICE_LIMIT
                    : MAX_PRICE_LIMIT
            });
        // TODO: may need a way to halt to prevent perpetual stop loss triggers
        BalanceDelta delta = UniV4UserHook.swap(
            poolKey,
            stopLossSwapParams,
            address(this)
        );
        // remove this position once is fullfilled

        // capital from the swap is redeemable by position holders
        //uint256 tokenId = getTokenId(poolKey, triggerTick, percent, zeroForOne);

        // TODO: safe casting
        // balance delta returned by .swap(): negative amount indicates outflow from pool (and inflow into contract)
        // therefore, we need to invert
        uint256 amount = zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));

        uint256[] memory trailingIds = trailingByTicksId[poolKey.toId()][
            triggerTick
        ][zeroForOne];

        for (uint i = 0; i < trailingIds.length; i++) {
            uint256 trailingId = trailingIds[i];
            TrailingInfo storage trailing = tokenIdIndex[trailingId];
            // todo correct calculation
            trailing.filledAmount += amount;

            // delete this trailing from list of active trailings
            uint256[] storage trailingActives = trailingByPercentActive[
                poolKey.toId()
            ][trailing.percent][zeroForOne];
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
        delete trailingByTicksId[poolKey.toId()][triggerTick][zeroForOne];
        delete trailingPositions[poolKey.toId()][triggerTick][zeroForOne];
    }

    // -- Trailing stop User Facing Functions -- //
    function placeTrailingLoss(
        PoolKey calldata poolKey,
        uint24 percent,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24 tick) {
        // between 1 and 10%, with a step of 1
        if (percent < 10_000 || percent > 100_000 || percent % 10_000 != 0) {
            revert IncorrectPercentage(percent);
        }

        (, int24 tickSlot, , ) = StateLibrary.getSlot0(
            poolManager,
            poolKey.toId()
        );
        // calculate ticklower base on percent trailing stop
        int24 tickLower = tickSlot - ((tickSlot * int24(percent)) / 10_000);
        // round down according to tickSpacing
        // TODO: should we round up depending on direction of the position?
        tick = getTickLower(tickLower, poolKey.tickSpacing);
        // TODO: safe casting
        trailingPositions[poolKey.toId()][tick][zeroForOne] += int256(amountIn);

        // found corresponding trailing in existing list
        uint256 tokenId = 0;
        uint256[] storage listTrailing = trailingByPercentActive[
            poolKey.toId()
        ][percent][zeroForOne];
        if (listTrailing.length > 0) {
            TrailingInfo storage data = tokenIdIndex[tokenId];
            if (data.filledAmount == 0 && data.tickLower <= tickLower) {
                // we merge data only if the price is more or the same
                data.tickLower = tickLower;
            } else {
                // else we create a new trailing
                lastTokenId++;
                tokenId = lastTokenId;
                data.poolKey = poolKey;
                data.tickLower = tickLower;
                data.zeroForOne = zeroForOne;
                data.percent = percent;
            }
        } else {
            TrailingInfo memory data = tokenIdIndex[tokenId];
            if (data.filledAmount == 0 && data.tickLower <= tickLower) {
                // we merge data only if the price is more or the same
                data.tickLower = tickLower;
            } else {
                // else we create a new trailing
                lastTokenId++;
                tokenId = lastTokenId;
                data.poolKey = poolKey;
                data.tickLower = tickLower;
                data.zeroForOne = zeroForOne;
                data.percent = percent;
            }
        }

        // mint the receipt token
        _mint(msg.sender, tokenId, amountIn);

        // interactions: transfer token0 to this contract
        address token = zeroForOne
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
    }

    // TODO: implement, is out of scope for the hackathon
    function killStopLoss() external {}

    // ------------------------------------- //

    function redeem(
        uint256 tokenId,
        uint256 amountIn,
        address destination
    ) external {
        // checks: an amount to redeem
        require(claimable[tokenId] > 0, "StopLoss: no claimable amount");
        uint256 receiptBalance = balanceOf[msg.sender][tokenId];
        require(
            amountIn <= receiptBalance,
            "StopLoss: not enough tokens to redeem"
        );

        TrailingInfo memory data = tokenIdIndex[tokenId];
        address token = data.zeroForOne
            ? Currency.unwrap(data.poolKey.currency1)
            : Currency.unwrap(data.poolKey.currency0);

        // effects: burn the token
        // amountOut = claimable * (amountIn / totalSupply)
        uint256 amountOut = amountIn.mulDivDown(
            claimable[tokenId],
            totalSupply[tokenId]
        );
        claimable[tokenId] -= amountOut;
        _burn(msg.sender, tokenId, amountIn);
        totalSupply[tokenId] -= amountIn;

        // interaction: transfer the underlying to the caller
        IERC20(token).transfer(destination, amountOut);
    }

    // ---------- //

    // -- Util functions -- //
    function rebalanceTrailings(
        PoolId poolId,
        uint24 percent,
        int24 newTick,
        bool zeroForOne
    ) private {
        uint256[] memory activeTrailings = trailingByPercentActive[poolId][
            percent
        ][zeroForOne];

        for (uint i = 0; i < activeTrailings.length; i++) {}
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
}
