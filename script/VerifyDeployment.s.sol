// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/console2.sol";
import {BatchPermitSweeper} from "../src/BatchPermitSweeper.sol";
import {DeploymentConfig} from "./DeploymentConfig.sol";

contract VerifyDeployment is DeploymentConfig {
    /// @notice Read-only verification BEFORE any owner configuration transactions.
    function run() external view {
        Config memory config = _readConfig();
        address deployed = vm.envAddress("SWEEPER_ADDRESS");
        require(deployed.code.length > 0, "NO_DEPLOYMENT");
        require(keccak256(deployed.code) == keccak256(type(BatchPermitSweeper).runtimeCode), "BYTECODE_MISMATCH");
        BatchPermitSweeper instance = BatchPermitSweeper(deployed);
        require(instance.owner() == config.owner, "OWNER_MISMATCH");
        require(instance.pendingOwner() == address(0), "PENDING_OWNER");
        require(instance.recipient() == config.recipient, "RECIPIENT_MISMATCH");
        require(instance.paused(), "NOT_PAUSED");
        require(instance.configVersion() == 1, "ALREADY_CONFIGURED");
        require(instance.recipientChangeNonce() == 0, "UNEXPECTED_PROPOSAL_HISTORY");
        for (uint256 i; i < config.workers.length; ++i) {
            require(instance.isOperator(config.workers[i]), "WORKER_MISSING");
        }
        console2.log("Initial deployment verified", deployed);
    }
}
