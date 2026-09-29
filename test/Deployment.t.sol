// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {DeploymentConfig} from "../script/DeploymentConfig.sol";

contract ConfigHarness is DeploymentConfig {
    function validate(Config memory config) external view {
        _validate(config);
    }
}

contract SafeShape {
    uint256 public threshold = 2;
    address[] private signers;

    constructor() {
        signers.push(address(0x11));
        signers.push(address(0x12));
        signers.push(address(0x13));
    }

    function getThreshold() external view returns (uint256) { return threshold; }
    function getOwners() external view returns (address[] memory) { return signers; }
    function setThreshold(uint256 value) external { threshold = value; }
}

contract DeploymentTest is Test {
    ConfigHarness private harness;
    DeploymentConfig.Config private config;
    SafeShape private safe;

    function setUp() public {
        harness = new ConfigHarness();
        safe = new SafeShape();
        config.chainId = block.chainid;
        config.owner = address(safe);
        config.recipient = address(0x1234);
        config.workers.push(address(0x2345));
        config.requireSafeOwner = true;
    }

    function testValidMultiSigShapeAccepted() public view {
        harness.validate(config);
    }

    function testWrongNetworkRejected() public {
        config.chainId = block.chainid + 1;
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfig.WrongChain.selector, config.chainId, block.chainid));
        harness.validate(config);
    }

    function testEOAOwnerRequiresExplicitOptOut() public {
        config.owner = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfig.SafeOwnerRequired.selector, config.owner));
        harness.validate(config);
        config.requireSafeOwner = false;
        harness.validate(config);
    }

    function testWrongThresholdRejected() public {
        safe.setThreshold(1);
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfig.InvalidSafeThreshold.selector, 1, 3));
        harness.validate(config);
    }

    function testOwnerCannotBeInitialWorkerInDeploymentPolicy() public {
        config.workers[0] = config.owner;
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfig.OwnerIsWorker.selector, config.owner));
        harness.validate(config);
    }

    function testDuplicateWorkersRejected() public {
        config.workers.push(config.workers[0]);
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfig.DuplicateWorker.selector, config.workers[0]));
        harness.validate(config);
    }

    function testZeroRecipientRejected() public {
        config.recipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfig.InvalidConfigAddress.selector, address(0)));
        harness.validate(config);
    }
}
