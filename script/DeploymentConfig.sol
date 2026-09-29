// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";

interface ISafeOwner {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

abstract contract DeploymentConfig is Script {
    struct Config {
        uint256 chainId;
        address owner;
        address recipient;
        address[] workers;
        bool requireSafeOwner;
    }

    error WrongChain(uint256 expected, uint256 actual);
    error InvalidConfigAddress(address account);
    error DuplicateWorker(address worker);
    error OwnerIsWorker(address worker);
    error SafeOwnerRequired(address owner);
    error InvalidSafeThreshold(uint256 threshold, uint256 signerCount);

    function _readConfig() internal view returns (Config memory config) {
        string memory path = vm.envOr("DEPLOY_CONFIG", string("config/deployment.local.json"));
        string memory json = vm.readFile(path);
        config.chainId = vm.parseJsonUint(json, ".chainId");
        config.owner = vm.parseJsonAddress(json, ".owner");
        config.recipient = vm.parseJsonAddress(json, ".recipient");
        config.workers = vm.parseJsonAddressArray(json, ".workers");
        config.requireSafeOwner = vm.parseJsonBool(json, ".requireSafeOwner");
        _validate(config);
    }

    function _validate(Config memory config) internal view {
        if (config.chainId == 0 || config.chainId != block.chainid) revert WrongChain(config.chainId, block.chainid);
        if (config.owner == address(0)) revert InvalidConfigAddress(config.owner);
        if (config.recipient == address(0)) revert InvalidConfigAddress(config.recipient);
        for (uint256 i; i < config.workers.length; ++i) {
            address worker = config.workers[i];
            if (worker == address(0)) revert InvalidConfigAddress(worker);
            if (worker == config.owner) revert OwnerIsWorker(worker);
            for (uint256 j; j < i; ++j) {
                if (worker == config.workers[j]) revert DuplicateWorker(worker);
            }
        }
        if (config.requireSafeOwner) {
            if (config.owner.code.length == 0) revert SafeOwnerRequired(config.owner);
            uint256 threshold = ISafeOwner(config.owner).getThreshold();
            address[] memory signers = ISafeOwner(config.owner).getOwners();
            if (threshold != 2 || signers.length != 3) revert InvalidSafeThreshold(threshold, signers.length);
            for (uint256 i; i < signers.length; ++i) {
                if (signers[i] == address(0)) revert InvalidConfigAddress(signers[i]);
                for (uint256 j; j < i; ++j) {
                    if (signers[i] == signers[j]) revert InvalidConfigAddress(signers[i]);
                }
            }
        }
    }
}
