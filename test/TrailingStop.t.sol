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
import {TrailingStopHook} from "../src/TrailingStopHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract TrailingStopTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address bob = makeAddr("bob");
    address alice = makeAddr("alice");
    address dylan = makeAddr("dylan");

    TrailingStopHook trailingHook;
    PoolId poolId;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(TrailingStopHook).creationCode,
            abi.encode(address(manager))
        );
        trailingHook = new TrailingStopHook{salt: salt}(
            IPoolManager(address(manager))
        );
        require(
            address(trailingHook) == hookAddress,
            "TrailingTest: hook address mismatch"
        );

        // Create the pool
        key = PoolKey(
            currency0,
            currency1,
            3000,
            // this hook works only with a tick spacing of 50
            50,
            IHooks(address(trailingHook))
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-50, 50, 10 ether, 0),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-100, 100, 10 ether, 0),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(50),
                TickMath.maxUsableTick(50),
                10 ether,
                0
            ),
            ZERO_BYTES
        );
    }

    function testSwap() public {
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

    function testModifyLiquidityHooks() public {
        // remove liquidity
        int256 liquidityDelta = -1e18;
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-50, 50, liquidityDelta, 0),
            ZERO_BYTES
        );
    }

    function testIncorrectTickSpacing() public {
        // remove liquidity
        int256 liquidityDelta = -1e18;
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-60, 60, liquidityDelta, 0),
            ZERO_BYTES
        );
    }

    function testPlaceTrailing() public {
        address token0 = Currency.unwrap(currency0);
        deal(token0, bob, 1 ether);

        uint24 onePercent = 10_000;

        //trailingHook.trailingPositions(poolId,)
        (, int24 tickSlot, , ) = StateLibrary.getSlot0(manager, key.toId());
        int24 tickPercent = tickSlot - ((100 * int24(onePercent)) / 10_000);
        int24 tickLower = getTickLower(tickPercent, key.tickSpacing);

        assertEq(tickLower, -100);

        uint256 amount = trailingHook.trailingPositions(
            poolId,
            tickLower,
            true
        );
        assertEq(0, amount);

        uint256 activeLength = trailingHook.countActiveTrailingByPercent(
            poolId,
            onePercent,
            true
        );

        uint256 tickLength = trailingHook.countTrailingByTicks(
            poolId,
            tickLower,
            true
        );

        assertEq(0, activeLength);
        assertEq(0, tickLength);

        vm.startPrank(bob);
        IERC20(token0).approve(address(trailingHook), 1 ether);
        // 10_000 for 1%
        (int24 tickTrailing, uint256 trailingId) = trailingHook.placeTrailing(
            key,
            onePercent,
            0.5 ether,
            true
        );
        vm.stopPrank();

        assertEq(trailingId, 1);
        assertEq(tickTrailing, tickLower);

        uint256 amountAfter = trailingHook.trailingPositions(
            poolId,
            tickLower,
            true
        );
        assertEq(0.5 ether, amountAfter);

        uint256 balance = trailingHook.balanceOf(bob, trailingId);
        assertEq(0.5 ether, balance);

        activeLength = trailingHook.countActiveTrailingByPercent(
            poolId,
            onePercent,
            true
        );
        uint256 idActive = trailingHook.trailingByPercentActive(
            poolId,
            onePercent,
            true,
            0
        );

        assertEq(1, activeLength);
        assertEq(1, idActive);

        tickLength = trailingHook.countTrailingByTicks(poolId, tickLower, true);
        uint256 idTickList = trailingHook.trailingByTicksId(
            poolId,
            tickLower,
            true,
            0
        );

        assertEq(tickLength, 1);
        assertEq(idTickList, 1);
    }

    function testRemoveTrailing() public {
        address token0 = Currency.unwrap(currency0);
        deal(token0, bob, 1 ether);

        uint24 onePercent = 10_000;

        //trailingHook.trailingPositions(poolId,)
        (, int24 tickSlot, , ) = StateLibrary.getSlot0(manager, key.toId());
        int24 tickPercent = tickSlot - ((100 * int24(onePercent)) / 10_000);
        int24 tickLower = getTickLower(tickPercent, key.tickSpacing);

        vm.startPrank(bob);
        IERC20(token0).approve(address(trailingHook), 1 ether);
        // 10_000 for 1%
        (int24 tickTrailing, uint256 trailingId) = trailingHook.placeTrailing(
            key,
            onePercent,
            0.5 ether,
            true
        );
        vm.stopPrank();

        uint256 balance0 = IERC20(token0).balanceOf(bob);

        uint256 balance = trailingHook.balanceOf(bob, trailingId);
        assertEq(0.5 ether, balance);
        assertEq(0.5 ether, balance0);

        vm.startPrank(bob);
        trailingHook.removeTrailing(1);
        vm.stopPrank();

        // user retrieve his token
        balance0 = IERC20(token0).balanceOf(bob);
        balance = trailingHook.balanceOf(bob, trailingId);
        assertEq(0, balance);
        assertEq(1 ether, balance0);
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
