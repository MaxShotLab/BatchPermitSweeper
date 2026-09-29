// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/console2.sol";
import {BatchPermitSweeper} from "../src/BatchPermitSweeper.sol";
import {DeploymentConfig} from "./DeploymentConfig.sol";

contract Deploy is DeploymentConfig {
    /// @dev No private keys in config or scripts. Select a keystore/hardware signer through forge CLI.
    function run() external returns (BatchPermitSweeper instance) {
        Config memory config = _readConfig();
        vm.startBroadcast();
        instance = new BatchPermitSweeper(config.owner, config.recipient, config.workers);
        vm.stopBroadcast();
        require(instance.owner() == config.owner, "OWNER_MISMATCH");
        require(instance.recipient() == config.recipient, "RECIPIENT_MISMATCH");
        require(instance.paused() && instance.configVersion() == 1, "UNEXPECTED_INITIAL_STATE");
        for (uint256 i; i < config.workers.length; ++i) {
            require(instance.isOperator(config.workers[i]), "WORKER_MISSING");
        }
        console2.log("Sweeper", address(instance));
        console2.log("Owner", config.owner);
        console2.log("Recipient", config.recipient);
        console2.log("Workers", config.workers.length);
        console2.log("Paused: true. Owner must allowlist reviewed tokens and explicitly unpause.");
    }
}
