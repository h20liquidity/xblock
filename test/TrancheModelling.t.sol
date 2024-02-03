// SPDX-License-Identifier: CAL
pragma solidity =0.8.19;

import {Vm} from "forge-std/Vm.sol";
import {console2, Test} from "forge-std/Test.sol";
import {
    XBlockStratUtil,
    IInterpreterV2,
    IInterpreterStoreV1,
    SourceIndexV2,
    StateNamespace,
    LibNamespace,
    FullyQualifiedNamespace    
} from "test/util/XBlockStratUtils.sol";
import {LibEncodedDispatch} from "rain.orderbook/lib/rain.interpreter/src/lib/caller/LibEncodedDispatch.sol";
import {
    XBLOCK_TOKEN,
    USDT_TOKEN,
    XBLOCK_TOKEN_HOLDER,
    USDT_TOKEN_HOLDER,
    VAULT_ID,
    OrderV2,
    TARGET_COOLDOWN_18,
    TRACKER,
    SEED
} from "src/XBlockStrat.sol";
import "rain.orderbook/lib/rain.math.fixedpoint/src/lib/LibFixedPointDecimalArithmeticOpenZeppelin.sol";
import "rain.orderbook/lib/rain.math.fixedpoint/src/lib/LibFixedPointDecimalScale.sol";
import "rain.orderbook/lib/rain.interpreter/src/lib/bitwise/LibCtPop.sol";

contract XBlockModelling is XBlockStratUtil {
    using LibFixedPointDecimalArithmeticOpenZeppelin for uint256;
    using LibFixedPointDecimalScale for uint256;

    bytes32 constant ORDER_HASH = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    address constant ORDER_OWNER = address(0x19f95a84aa1C48A2c6a7B2d5de164331c86D030C);
    address constant APPROVED_COUNTERPARTY = address(0x19f95a84aa1C48A2c6a7B2d5de164331c86D030C);
    address constant INPUT_ADDRESS = address(XBLOCK_TOKEN);
    address constant OUTPUT_ADDRESS = address(USDT_TOKEN);

    function test_trancheModelling() public {
        uint256[] memory stack = eval(getTrancheSellOrder());
        // if (vm.exists('./test/stacks.csv')) vm.removeFile('./test/stacks.csv');

        for (uint256 i = 0; i < stack.length; i++) {
            console2.logUint(stack[i]);
        }
    }

    function eval(bytes memory rainlang) public returns (uint256[] memory) {
        (bytes memory bytecode, uint256[] memory constants) = PARSER.parse(rainlang);
        (,,address expression,) = EXPRESSION_DEPLOYER.deployExpression2(bytecode, constants);

        uint256[][] memory context = buildContext();

        FullyQualifiedNamespace namespace =
            LibNamespace.qualifyNamespace(StateNamespace.wrap(uint256(uint160(ORDER_OWNER))), address(ORDERBOOK));

        (uint256[] memory stack,) = IInterpreterV2(INTERPRETER).eval2(
            IInterpreterStoreV1(address(STORE)),
            namespace,
            LibEncodedDispatch.encode2(expression, SourceIndexV2.wrap(0), type(uint16).max),
            context,
            new uint256[](0)
        );
        return stack;
    }

    function buildContext() public pure returns (uint256[][] memory) {
        uint256[][] memory context = new uint256[][](5);

        {
            uint256[] memory baseContext = new uint256[](2);
            context[0] = baseContext;
        }
        {
            uint256[] memory callingContext = new uint256[](3);
            // order hash
            callingContext[0] = uint256(ORDER_HASH);
            // owner
            callingContext[1] = uint256(uint160(address(ORDER_OWNER)));
            // counterparty
            callingContext[2] = uint256(uint160(APPROVED_COUNTERPARTY));
            context[1] = callingContext;
        }
        {
            uint256[] memory calculationsContext = new uint256[](0);
            context[2] = calculationsContext;
        }
        {
            uint256[] memory inputsContext = new uint256[](CONTEXT_VAULT_IO_ROWS);
            inputsContext[0] = uint256(uint160(address(INPUT_ADDRESS)));
            context[3] = inputsContext;
        }
        {
            uint256[] memory outputsContext = new uint256[](CONTEXT_VAULT_IO_ROWS);
            outputsContext[0] = uint256(uint160(address(OUTPUT_ADDRESS)));
            context[4] = outputsContext;
        }
        return context;
    }


}