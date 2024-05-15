// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @param _token ERC20 token
 * @dev decimals() method is optional, this function safely checks for decimals and if not returns 18
 */
function _safeDecimals(address _token) view returns (uint8) {
    (bool success, bytes memory data) = _token.staticcall(abi.encodeWithSignature("decimals()"));
    if (!success) {
        return 18; // Default to 18 decimals if the call fails
    }
    return abi.decode(data, (uint8));
}
