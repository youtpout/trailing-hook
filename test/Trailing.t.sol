// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {TrailingHook} from "../src/TrailingHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract TrailingTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    TrailingHook trailing;
    PoolId poolId;
    int24 constant MAX_TICK_SPACING = 32767;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(TrailingHook).creationCode,
            abi.encode(address(manager))
        );
        trailing = new TrailingHook{salt: salt}(IPoolManager(address(manager)));
        require(
            address(trailing) == hookAddress,
            "TrailingTest: hook address mismatch"
        );

        // Create the pool
        key = PoolKey(
            currency0,
            currency1,
            3000,
            MAX_TICK_SPACING,
            IHooks(address(trailing))
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                -MAX_TICK_SPACING,
                MAX_TICK_SPACING,
                10 ether,
                0
            ),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                -2 * MAX_TICK_SPACING,
                2 * MAX_TICK_SPACING,
                10 ether,
                0
            ),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(MAX_TICK_SPACING),
                TickMath.maxUsableTick(MAX_TICK_SPACING),
                10 ether,
                0
            ),
            ZERO_BYTES
        );
    }

    function testTrailingsHooks() public {
        // Perform a test swap //
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!
        BalanceDelta swapDelta = swap(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES
        );
        // ------------------- //
    }

    function testLiquidityHooks() public {
        // positions were created in setup()

        // remove liquidity
        int256 liquidityDelta = -1e18;
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                -MAX_TICK_SPACING,
                MAX_TICK_SPACING,
                liquidityDelta,
                0
            ),
            ZERO_BYTES
        );
    }
}
