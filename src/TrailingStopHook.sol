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
import "forge-std/Test.sol";

/// @notice This hook can execute trialing stop orders between 1 and 10%, with a step of 1.
/// Larger values limit the interest of such a hook and avoid having to manage too many data, which would be gas-consuming.
/// Based on https://github.com/saucepoint/v4-stoploss/blob/881a13ac3451b0cdab0e19e122e889f1607520b7/src/StopLoss.sol#L17
contract TrailingStopHook is UniV4UserHook, ERC6909, Test {
    using FixedPointMathLib for uint256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount)))
        public stopLossPositions;

    // -- 1155 state -- //
    mapping(uint256 tokenId => TokenIdData) public tokenIdIndex;
    mapping(uint256 tokenId => bool) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public claimable;
    mapping(uint256 tokenId => uint256 supply) public totalSupply;

    struct TokenIdData {
        PoolKey poolKey;
        int24 tickLower;
        bool zeroForOne;
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
                beforeSwap: false,
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

        // fill stop losses in the opposite direction of the swap
        // avoids abuse/attack vectors
        bool stopLossZeroForOne = !params.zeroForOne;

        // TODO: test for off by one because of inequality
        if (prevTick < currentTick) {
            for (; tick < currentTick; ) {
                swapAmounts = stopLossPositions[key.toId()][tick][
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
                swapAmounts = stopLossPositions[key.toId()][tick][
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
        stopLossPositions[poolKey.toId()][triggerTick][
            zeroForOne
        ] -= swapAmount;

        // capital from the swap is redeemable by position holders
        uint256 tokenId = getTokenId(poolKey, triggerTick, zeroForOne);

        // TODO: safe casting
        // balance delta returned by .swap(): negative amount indicates outflow from pool (and inflow into contract)
        // therefore, we need to invert
        uint256 amount = zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));
        claimable[tokenId] += amount;
    }

    // -- Stop Loss User Facing Functions -- //
    function placeStopLoss(
        PoolKey calldata poolKey,
        int24 tickLower,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24 tick) {
        // round down according to tickSpacing
        // TODO: should we round up depending on direction of the position?
        tick = getTickLower(tickLower, poolKey.tickSpacing);
        // TODO: safe casting
        stopLossPositions[poolKey.toId()][tick][zeroForOne] += int256(amountIn);

        // mint the receipt token
        uint256 tokenId = getTokenId(poolKey, tick, zeroForOne);
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdIndex[tokenId] = TokenIdData({
                poolKey: poolKey,
                tickLower: tick,
                zeroForOne: zeroForOne
            });
        }
        _mint(msg.sender, tokenId, amountIn);
        totalSupply[tokenId] += amountIn;

        // interactions: transfer token0 to this contract
        address token = zeroForOne
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
    }

    // TODO: implement, is out of scope for the hackathon
    function killStopLoss() external {}
    // ------------------------------------- //

    function getTokenId(
        PoolKey calldata poolKey,
        int24 tickLower,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(poolKey.toId(), tickLower, zeroForOne)
                )
            );
    }

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

        TokenIdData memory data = tokenIdIndex[tokenId];
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
