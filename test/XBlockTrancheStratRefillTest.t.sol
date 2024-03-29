// SPDX-License-Identifier: CAL
pragma solidity =0.8.19;

import {Vm} from "forge-std/Vm.sol";
import {console2, Test} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {
    XBlockStratUtil,
    IInterpreterV2,
    IInterpreterStoreV1,
    SourceIndexV2,
    StateNamespace,
    LibNamespace,
    FullyQualifiedNamespace
} from "test/util/XBlockStratUtils.sol";
import {EvaluableConfigV3, SignedContextV1} from "rain.interpreter/interface/IInterpreterCallerV2.sol";
import {
    LOCK_TOKEN,
    WETH_TOKEN,
    LOCK_TOKEN_HOLDER,
    WETH_TOKEN_HOLDER,
    VAULT_ID,
    OrderV2,
    LOCK_OWNER,
    SafeERC20,
    IERC20,
    IO,
    DAI_TOKEN_HOLDER,
    DAI_TOKEN,
    APPROVED_EOA,
    TakeOrderConfigV2,
    TakeOrdersConfigV2,
    LibTrancheRefillOrders,
    IHoudiniSwapToken,
    TRANCHE_SIZE_BASE_SELL,
    TRANCHE_SIZE_BASE_BUY,
    TRANCHE_SPACE_MIN_DIFF,
    TRANCHE_SPACE_RECHARGE_DELAY
} from "src/XBlockStratTrancheRefill.sol";
import {LibOrder} from "rain.orderbook/src/lib/LibOrder.sol";
import {LibEncodedDispatch} from "rain.orderbook/lib/rain.interpreter/src/lib/caller/LibEncodedDispatch.sol";
import "rain.orderbook/lib/rain.interpreter/lib/rain.math.saturating/src/SaturatingMath.sol";
import "rain.orderbook/lib/rain.math.fixedpoint/src/lib/LibFixedPointDecimalArithmeticOpenZeppelin.sol";
import "rain.orderbook/lib/rain.math.fixedpoint/src/lib/LibFixedPointDecimalScale.sol";

contract XBlockTrancheStratRefillTest is XBlockStratUtil {
    using SafeERC20 for IERC20;
    using LibOrder for OrderV2;

    using LibFixedPointDecimalArithmeticOpenZeppelin for uint256;
    using LibFixedPointDecimalScale for uint256;

    address constant TEST_ORDER_OWNER = address(0x84723849238);

    function launchLockToken() public {
        vm.startPrank(LOCK_OWNER);
        IHoudiniSwapToken(address(LOCK_TOKEN)).launch();
        vm.stopPrank();
    }

    function lockExclude(address[] memory accounts, bool value) public {
        vm.startPrank(LOCK_OWNER);
        IHoudiniSwapToken(address(LOCK_TOKEN)).excludeFromLimits(accounts, value);
        vm.stopPrank();
    }

    function setAMMPair(address ammContract) public {
        vm.startPrank(LOCK_OWNER);
        IHoudiniSwapToken(address(LOCK_TOKEN)).setAutomatedMarketMakerPair(ammContract, true);
        vm.stopPrank();
    }

    function lockIo() internal pure returns (IO memory) {
        return IO(address(LOCK_TOKEN), 18, VAULT_ID);
    }

    function wethIo() internal pure returns (IO memory) {
        return IO(address(WETH_TOKEN), 18, VAULT_ID);
    }

    function testTrancheRefillTakeBuyOrder() public {
        string memory file = "./test/csvs/tranche-amount-io.csv";
        if (vm.exists(file)) vm.removeFile(file);

        vm.writeLine(file, string.concat("Timestamp", ",", "Amount", ",", "Price"));

        uint256 maxAmountPerTakeOrder = type(uint256).max;
        {
            uint256 depositAmount = type(uint256).max;
            deal(address(WETH_TOKEN), TEST_ORDER_OWNER, depositAmount);
            depositTokens(TEST_ORDER_OWNER, WETH_TOKEN, VAULT_ID, depositAmount);
        }
        OrderV2 memory trancheOrder;
        {
            (bytes memory bytecode, uint256[] memory constants) = PARSER.parse(
                LibTrancheRefillOrders.getTrancheRefillBuyOrder(vm, address(ORDERBOOK_SUPARSER), address(UNISWAP_WORDS))
            );
            trancheOrder = placeOrder(TEST_ORDER_OWNER, bytecode, constants, lockIo(), wethIo());
        }

        uint256 inputIOIndex = 0;
        uint256 outputIOIndex = 0;

        TakeOrderConfigV2[] memory innerConfigs = new TakeOrderConfigV2[](1);

        innerConfigs[0] = TakeOrderConfigV2(trancheOrder, inputIOIndex, outputIOIndex, new SignedContextV1[](0));
        TakeOrdersConfigV2 memory takeOrdersConfig =
            TakeOrdersConfigV2(0, maxAmountPerTakeOrder, type(uint256).max, innerConfigs, "");

        deal(address(LOCK_TOKEN), APPROVED_EOA, type(uint256).max);
        vm.startPrank(APPROVED_EOA);
        IERC20(address(LOCK_TOKEN)).safeApprove(address(ORDERBOOK), type(uint256).max);

        for (uint256 i = 0; i < 1; i++) {
            vm.recordLogs();
            ORDERBOOK.takeOrders(takeOrdersConfig);
            Vm.Log[] memory entries = vm.getRecordedLogs();

            uint256 amount;
            uint256 ratio;

            for (uint256 j = 0; j < entries.length; j++) {
                if (entries[j].topics[0] == keccak256("Context(address,uint256[][])")) {
                    (, uint256[][] memory context) = abi.decode(entries[j].data, (address, uint256[][]));
                    amount = context[2][0];
                    ratio = context[2][1];
                }
            }

            uint256 time = block.timestamp + 60 * 4; // moving forward 4 minutes

            string memory line = string.concat(uint2str(time), ",", uint2str(amount), ",", uint2str(ratio));

            vm.writeLine(file, line);

            vm.warp(time);
        }

        vm.stopPrank();
    }

    function testTrancheRefillBuyOrderHappyFork() public {
        setAMMPair(address(ARB_INSTANCE));
        {
            uint256 depositAmount = 10000e18;
            giveTestAccountsTokens(WETH_TOKEN, WETH_TOKEN_HOLDER, TEST_ORDER_OWNER, depositAmount);
            depositTokens(TEST_ORDER_OWNER, WETH_TOKEN, VAULT_ID, depositAmount);
        }
        OrderV2 memory trancheOrder;
        {
            (bytes memory bytecode, uint256[] memory constants) = PARSER.parse(
                LibTrancheRefillOrders.getTrancheRefillBuyOrder(vm, address(ORDERBOOK_SUPARSER), address(UNISWAP_WORDS))
            );
            trancheOrder = placeOrder(TEST_ORDER_OWNER, bytecode, constants, xBlockIo(), wethIo());
        }
        moveUniswapV3Price(
            address(LOCK_TOKEN), address(WETH_TOKEN), LOCK_TOKEN_HOLDER, 11000000e18, getEncodedLockSellRoute()
        );
        for (uint256 i = 0; i < 3; i++) {
            takeOrder(trancheOrder, getEncodedLockBuyRoute());
            vm.warp(block.timestamp + TRANCHE_SPACE_RECHARGE_DELAY + 1);
            vm.expectRevert(bytes("Minimum trade size not met."));
            takeOrder(trancheOrder, getEncodedLockBuyRoute());
            vm.warp(block.timestamp + 43200);
        }
    }

    function testTrancheRefillSellOrderHappyFork() public {
        setAMMPair(address(ARB_INSTANCE));
        {
            uint256 depositAmount = 3000000e18;
            giveTestAccountsTokens(LOCK_TOKEN, LOCK_TOKEN_HOLDER, TEST_ORDER_OWNER, depositAmount);
            depositTokens(TEST_ORDER_OWNER, LOCK_TOKEN, VAULT_ID, depositAmount);
        }
        OrderV2 memory trancheOrder;
        {
            (bytes memory bytecode, uint256[] memory constants) = PARSER.parse(
                LibTrancheRefillOrders.getTrancheRefillSellOrder(
                    vm, address(ORDERBOOK_SUPARSER), address(UNISWAP_WORDS)
                )
            );
            trancheOrder = placeOrder(TEST_ORDER_OWNER, bytecode, constants, wethIo(), xBlockIo());
        }
        moveUniswapV3Price(
            address(WETH_TOKEN), address(LOCK_TOKEN), WETH_TOKEN_HOLDER, 10000e18, getEncodedLockBuyRoute()
        );
        for (uint256 i = 0; i < 3; i++) {
            takeOrder(trancheOrder, getEncodedLockSellRoute());
            vm.warp(block.timestamp + TRANCHE_SPACE_RECHARGE_DELAY + 1);
            vm.expectRevert(bytes("Minimum trade size not met."));
            takeOrder(trancheOrder, getEncodedLockSellRoute());
            vm.warp(block.timestamp + 43200);
        }
    }

    function testSellCalculateTranche(uint256 trancheSpaceBefore, uint256 delay) public {
        trancheSpaceBefore = bound(trancheSpaceBefore, 0, 100e18);
        delay = bound(delay, 1, 86400);
        uint256 lastTimeUpdate = block.timestamp;

        uint256[] memory stack1 = eval(
            LibTrancheRefillOrders.getTestCalculateTrancheSource(
                vm,
                address(ORDERBOOK_SUPARSER),
                address(UNISWAP_WORDS),
                TRANCHE_SIZE_BASE_SELL,
                trancheSpaceBefore,
                lastTimeUpdate,
                lastTimeUpdate + delay
            )
        );

        assertEq(stack1[2], SaturatingMath.saturatingSub(trancheSpaceBefore, stack1[4]));
        assertEq(stack1[3], lastTimeUpdate + delay);
    }

    function testBuyCalculateTranche(uint256 trancheSpaceBefore, uint256 delay) public {
        trancheSpaceBefore = bound(trancheSpaceBefore, 0, 100e18);
        delay = bound(delay, 1, 86400);
        uint256 lastTimeUpdate = block.timestamp;

        uint256[] memory stack1 = eval(
            LibTrancheRefillOrders.getTestCalculateTrancheSource(
                vm,
                address(ORDERBOOK_SUPARSER),
                address(UNISWAP_WORDS),
                TRANCHE_SIZE_BASE_BUY,
                trancheSpaceBefore,
                lastTimeUpdate,
                lastTimeUpdate + delay
            )
        );

        assertEq(stack1[2], SaturatingMath.saturatingSub(trancheSpaceBefore, stack1[4]));
        assertEq(stack1[3], lastTimeUpdate + delay);
    }

    function testSellHandleIo(uint256 outputTokenTraded, uint256 trancheSpaceBefore, uint256 delay) public {
        outputTokenTraded = bound(outputTokenTraded, 1e18, 1000000e18);
        trancheSpaceBefore = bound(trancheSpaceBefore, 0, 100e18);
        delay = bound(delay, 1, 86400);
        uint256 lastTimeUpdate = block.timestamp;

        FullyQualifiedNamespace namespace =
            LibNamespace.qualifyNamespace(StateNamespace.wrap(uint256(uint160(ORDER_OWNER))), address(ORDERBOOK));

        uint256[][] memory buyOrderContext = getBuyOrderContext(12345);
        buyOrderContext[4][1] = 18;

        {
            uint256[] memory calculateTrancheStack = eval(
                LibTrancheRefillOrders.getTestCalculateTrancheSource(
                    vm,
                    address(ORDERBOOK_SUPARSER),
                    address(UNISWAP_WORDS),
                    TRANCHE_SIZE_BASE_SELL,
                    trancheSpaceBefore,
                    lastTimeUpdate,
                    lastTimeUpdate + delay
                )
            );

            (bytes memory bytecode, uint256[] memory constants) = PARSER.parse(
                LibTrancheRefillOrders.getTestHandleIoSource(
                    vm,
                    address(ORDERBOOK_SUPARSER),
                    address(UNISWAP_WORDS),
                    TRANCHE_SIZE_BASE_SELL,
                    trancheSpaceBefore,
                    lastTimeUpdate,
                    lastTimeUpdate + delay
                )
            );
            (,, address handleIoExpression,) = EXPRESSION_DEPLOYER.deployExpression2(bytecode, constants);

            buyOrderContext[4][4] = outputTokenTraded;
            uint256 trancheSpaceAfter =
                trancheSpaceBefore + outputTokenTraded.fixedPointDiv(calculateTrancheStack[0], Math.Rounding.Down);

            if (trancheSpaceAfter < (trancheSpaceBefore + TRANCHE_SPACE_MIN_DIFF)) {
                vm.expectRevert(bytes("Minimum trade size not met."));
            }

            IInterpreterV2(INTERPRETER).eval2(
                IInterpreterStoreV1(address(STORE)),
                namespace,
                LibEncodedDispatch.encode2(handleIoExpression, SourceIndexV2.wrap(0), type(uint16).max),
                buyOrderContext,
                new uint256[](0)
            );
        }
    }

    function testBuyHandleIo(uint256 outputTokenTraded, uint256 trancheSpaceBefore, uint256 delay) public {
        outputTokenTraded = bound(outputTokenTraded, 1e10, 1000e18);
        trancheSpaceBefore = bound(trancheSpaceBefore, 0, 100e18);
        delay = bound(delay, 1, 86400);
        uint256 lastTimeUpdate = block.timestamp;

        FullyQualifiedNamespace namespace =
            LibNamespace.qualifyNamespace(StateNamespace.wrap(uint256(uint160(ORDER_OWNER))), address(ORDERBOOK));

        uint256[][] memory buyOrderContext = getBuyOrderContext(12345);
        buyOrderContext[4][1] = 18;

        {
            uint256[] memory calculateTrancheStack = eval(
                LibTrancheRefillOrders.getTestCalculateTrancheSource(
                    vm,
                    address(ORDERBOOK_SUPARSER),
                    address(UNISWAP_WORDS),
                    TRANCHE_SIZE_BASE_BUY,
                    trancheSpaceBefore,
                    lastTimeUpdate,
                    lastTimeUpdate + delay
                )
            );

            (bytes memory bytecode, uint256[] memory constants) = PARSER.parse(
                LibTrancheRefillOrders.getTestHandleIoSource(
                    vm,
                    address(ORDERBOOK_SUPARSER),
                    address(UNISWAP_WORDS),
                    TRANCHE_SIZE_BASE_BUY,
                    trancheSpaceBefore,
                    lastTimeUpdate,
                    lastTimeUpdate + delay
                )
            );
            (,, address handleIoExpression,) = EXPRESSION_DEPLOYER.deployExpression2(bytecode, constants);

            buyOrderContext[4][4] = outputTokenTraded;
            uint256 trancheSpaceAfter =
                trancheSpaceBefore + outputTokenTraded.fixedPointDiv(calculateTrancheStack[0], Math.Rounding.Down);

            if (trancheSpaceAfter < (trancheSpaceBefore + TRANCHE_SPACE_MIN_DIFF)) {
                vm.expectRevert(bytes("Minimum trade size not met."));
            }

            IInterpreterV2(INTERPRETER).eval2(
                IInterpreterStoreV1(address(STORE)),
                namespace,
                LibEncodedDispatch.encode2(handleIoExpression, SourceIndexV2.wrap(0), type(uint16).max),
                buyOrderContext,
                new uint256[](0)
            );
        }
    }
}
