// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

abstract contract UniV4UserHook is BaseHook {
    using CurrencyLibrary for Currency;
    bytes constant ZERO_BYTES = new bytes(0);

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    /**
     * @dev Swap tokens **owned** by the contract
     */
    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        address receiver
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(
                abi.encodeCall(this.handleSwap, (key, params, receiver))
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    // function modifyPosition(
    //     PoolKey memory key,
    //     IPoolManager.ModifyLiquidityParams memory params,
    //     address caller
    // ) internal returns (BalanceDelta delta) {
    //     delta = abi.decode(
    //         poolManager.unlock(
    //             abi.encodeCall(this.handleModifyPosition, (key, params, caller))
    //         ),
    //         (BalanceDelta)
    //     );

    //     uint256 ethBalance = address(this).balance;
    //     if (ethBalance > 0) {
    //         CurrencyLibrary.NATIVE.transfer(caller, ethBalance);
    //     }
    // }

    function handleSwap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        address sender
    ) external returns (BalanceDelta delta) {
        delta = poolManager.swap(key, params, ZERO_BYTES);

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                if (key.currency0.isNative()) {
                    poolManager.settle{value: uint128(delta.amount0())}(
                        key.currency0
                    );
                } else {
                    IERC20Minimal(Currency.unwrap(key.currency0)).transfer(
                        address(poolManager),
                        uint128(delta.amount0())
                    );
                    poolManager.settle(key.currency0);
                }
            }
            if (delta.amount1() < 0) {
                poolManager.take(
                    key.currency1,
                    sender,
                    uint128(-delta.amount1())
                );
            }
        } else {
            if (delta.amount1() > 0) {
                if (key.currency1.isNative()) {
                    poolManager.settle{value: uint128(delta.amount1())}(
                        key.currency1
                    );
                } else {
                    IERC20Minimal(Currency.unwrap(key.currency1)).transfer(
                        address(poolManager),
                        uint128(delta.amount1())
                    );
                    poolManager.settle(key.currency1);
                }
            }
            if (delta.amount0() < 0) {
                poolManager.take(
                    key.currency0,
                    sender,
                    uint128(-delta.amount0())
                );
            }
        }
    }

    // function handleModifyPosition(
    //     PoolKey memory key,
    //     IPoolManager.ModifyLiquidityParams memory params,
    //     address caller
    // ) external returns (BalanceDelta delta) {
    //     delta = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
    //     if (delta.amount0() > 0) {
    //         if (key.currency0.isNative()) {
    //             poolManager.settle{value: uint128(delta.amount0())}(
    //                 key.currency0
    //             );
    //         } else {
    //             IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(
    //                 caller,
    //                 address(poolManager),
    //                 uint128(delta.amount0())
    //             );
    //             poolManager.settle(key.currency0);
    //         }
    //     }
    //     if (delta.amount1() > 0) {
    //         if (key.currency1.isNative()) {
    //             poolManager.settle{value: uint128(delta.amount1())}(
    //                 key.currency1
    //             );
    //         } else {
    //             IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(
    //                 caller,
    //                 address(poolManager),
    //                 uint128(delta.amount1())
    //             );
    //             poolManager.settle(key.currency1);
    //         }
    //     }

    //     if (delta.amount0() < 0) {
    //         poolManager.take(key.currency0, caller, uint128(-delta.amount0()));
    //     }
    //     if (delta.amount1() < 0) {
    //         poolManager.take(key.currency1, caller, uint128(-delta.amount1()));
    //     }
    // }
}
