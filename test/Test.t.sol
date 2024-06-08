// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

contract TrailingTest is Test {
    mapping(uint256 poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount)))
        public complexMap;

    mapping(uint256 id => int256 amount) public simpleMap;

    function setUp() public {}

    function testComplexMap() public {
        for (uint i = 0; i < 100; i++) {
            complexMap[i][15][true] += 50;
        }
        /* for (uint i = 0; i < 100; i++) {
            delete complexMap[i][15][true];
        }*/
    }

    function testSimpleMap() public {
        for (uint i = 0; i < 100; i++) {
            simpleMap[i] += 50;
        }
        /*   for (uint i = 0; i < 100; i++) {
            delete simpleMap[i];
        }*/
    }
}
