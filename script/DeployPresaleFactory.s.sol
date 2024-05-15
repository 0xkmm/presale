// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {PresaleFactory} from "@src/core/PresaleFactory.sol";


contract DeployPresaleFactory is Script {
    function run() external returns (address) {
        return (address(new PresaleFactory()));
    }
}