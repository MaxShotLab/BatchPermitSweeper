// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {BatchPermitSweeper} from "../src/BatchPermitSweeper.sol";
import {PermitToken} from "./mocks/Tokens.sol";

abstract contract TestBase is Test {
    uint256 internal constant ALICE_KEY = 0xA11CE;
    uint256 internal constant BOB_KEY = 0xB0B;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    address internal alice;
    address internal bob;
    address internal worker = address(0x2000);
    address internal treasury = address(0x3000);
    BatchPermitSweeper internal sweeper;
    PermitToken internal token;

    function setUp() public virtual {
        vm.warp(1_000_000);
        alice = vm.addr(ALICE_KEY);
        bob = vm.addr(BOB_KEY);
        address[] memory workers = new address[](1);
        workers[0] = worker;
        sweeper = new BatchPermitSweeper(address(this), treasury, workers);
        token = new PermitToken();
        sweeper.setTokenAllowed(address(token), true);
        sweeper.unpause();
    }

    function _context() internal view returns (BatchPermitSweeper.SweepContext memory) {
        return BatchPermitSweeper.SweepContext(sweeper.recipient(), sweeper.configVersion(), block.timestamp + 10 minutes);
    }

    function _one(address source) internal pure returns (address[] memory sources) {
        sources = new address[](1);
        sources[0] = source;
    }

    function _two() internal view returns (address[] memory sources) {
        sources = new address[](2);
        (sources[0], sources[1]) = alice < bob ? (alice, bob) : (bob, alice);
    }

    function _fundAndApprove(address source, uint256 amount, uint256 approved) internal {
        token.mint(source, amount);
        vm.prank(source);
        token.approve(address(sweeper), approved);
    }

    function _permit(uint256 key, uint256 value, uint256 deadline)
        internal
        view
        returns (BatchPermitSweeper.PermitParam memory item)
    {
        address source = vm.addr(key);
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, source, address(sweeper), value, token.nonces(source), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        item = BatchPermitSweeper.PermitParam(source, value, deadline, v, r, s);
    }

    function _onePermit(BatchPermitSweeper.PermitParam memory item)
        internal
        pure
        returns (BatchPermitSweeper.PermitParam[] memory items)
    {
        items = new BatchPermitSweeper.PermitParam[](1);
        items[0] = item;
    }
}
