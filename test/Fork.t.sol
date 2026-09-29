// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {BatchPermitSweeper} from "../src/BatchPermitSweeper.sol";

/// @dev Opt-in test of an explicitly selected real token. All changes exist only on the local fork.
contract ForkTest is Test {
    function testConfiguredTokenPermitAndStandingAllowance() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        uint256 forkBlock = vm.envUint("FORK_BLOCK_NUMBER");
        require(forkBlock > 0, "PIN_A_FORK_BLOCK");
        vm.createSelectFork(rpc, forkBlock);
        address token = vm.envAddress("FORK_TOKEN");
        require(token.code.length > 0, "INVALID_FORK_TOKEN");
        address source = vm.addr(0xF01234);
        address treasury = address(0x987654);
        BatchPermitSweeper instance = new BatchPermitSweeper(address(this), treasury, new address[](0));
        instance.setTokenAllowed(token, true);
        instance.unpause();
        uint256 amount = 1_000_000;
        uint256 beforeBalance = IERC20(token).balanceOf(treasury);
        deal(token, source, amount);
        uint256 nonce = IERC20Permit(token).nonces(source);
        uint256 deadline = block.timestamp + 1800;
        bytes32 typeHash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 message = keccak256(abi.encode(typeHash, source, address(instance), type(uint256).max, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(token).DOMAIN_SEPARATOR(), message));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xF01234, digest);
        BatchPermitSweeper.PermitParam[] memory items = new BatchPermitSweeper.PermitParam[](1);
        items[0] = BatchPermitSweeper.PermitParam(source, type(uint256).max, deadline, v, r, s);
        BatchPermitSweeper.SweepContext memory context =
            BatchPermitSweeper.SweepContext(treasury, instance.configVersion(), block.timestamp + 600);
        instance.batchSweepWithPermit(token, items, context);
        assertEq(IERC20Permit(token).nonces(source), nonce + 1);
        deal(token, source, amount);
        address[] memory sources = new address[](1);
        sources[0] = source;
        instance.batchSweep(token, sources, context);
        assertEq(IERC20(token).balanceOf(treasury), beforeBalance + 2 * amount);
        assertEq(IERC20(token).balanceOf(source), 0);
    }
}
