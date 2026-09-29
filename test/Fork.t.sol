// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {BatchPermitSweeper} from "../src/BatchPermitSweeper.sol";

/// @dev Opt-in test of an explicitly selected real token. All changes exist only on the local fork.
contract ForkTest is Test {
    uint256 private constant SOURCE_KEY = 0xF01234;
    address private constant TREASURY = address(0x987654);
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    address private token;
    BatchPermitSweeper private instance;

    function testConfiguredTokenPermitAndStandingAllowance() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        uint256 forkBlock = vm.envUint("FORK_BLOCK_NUMBER");
        require(forkBlock > 0, "PIN_A_FORK_BLOCK");
        vm.createSelectFork(rpc, forkBlock);
        token = vm.envAddress("FORK_TOKEN");
        require(token.code.length > 0, "INVALID_FORK_TOKEN");
        address source = vm.addr(SOURCE_KEY);
        instance = new BatchPermitSweeper(address(this), TREASURY, new address[](0));
        instance.setTokenAllowed(token, true);
        instance.unpause();
        uint256 amount = 1_000_000;
        uint256 beforeBalance = IERC20(token).balanceOf(TREASURY);
        deal(token, source, amount);
        uint256 nonce = IERC20Permit(token).nonces(source);
        BatchPermitSweeper.SweepContext memory context =
            BatchPermitSweeper.SweepContext(TREASURY, instance.configVersion(), block.timestamp + 600);
        instance.batchSweepWithPermit(token, _signedPermit(source, nonce), context);
        assertEq(IERC20Permit(token).nonces(source), nonce + 1);
        deal(token, source, amount);
        address[] memory sources = new address[](1);
        sources[0] = source;
        instance.batchSweep(token, sources, context);
        assertEq(IERC20(token).balanceOf(TREASURY), beforeBalance + 2 * amount);
        assertEq(IERC20(token).balanceOf(source), 0);
    }

    function _signedPermit(address source, uint256 nonce)
        private
        view
        returns (BatchPermitSweeper.PermitParam[] memory items)
    {
        uint256 deadline = block.timestamp + 1800;
        bytes32 message =
            keccak256(abi.encode(PERMIT_TYPEHASH, source, address(instance), type(uint256).max, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(token).DOMAIN_SEPARATOR(), message));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SOURCE_KEY, digest);
        items = new BatchPermitSweeper.PermitParam[](1);
        items[0] = BatchPermitSweeper.PermitParam(source, type(uint256).max, deadline, v, r, s);
    }
}
