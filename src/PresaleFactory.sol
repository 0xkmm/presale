// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Presale, PresaleMetadata, PresaleParams, PresaleWhiteList, PresaleTokenInfo} from "./Presale.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PresaleFactory
 * @author kostadin-m
 * @notice This contract acts as a clone factory following the EIP1167 standard, improving on cheaper deployments for presales
 */
contract PresaleFactory {
    using Clones for address;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PresaleCreated(address indexed presale, address indexed owner);
    event ImplementationChanged(address indexed newImplementation);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev The implementation contract used to clone Presale contract (EIP1167)
    address private presaleImpl;

    ///@dev The owner of the contract
    address owner;

    ///@dev The uniswap factory address
    address public uniswapV2Factory;
    ///@dev The uniswap router address
    address public uniswapV2Router;
    ///@dev Adress of WETH token
    address public weth;

    ///@dev Setting the max fee to avoid big fees
    uint256 MAX_FEE = 5e16; // 5%

    /// @dev All of the presales. (Using enumerable set for easier adding/removing/tracking and to not make parallel storage variables)
    EnumerableSet.AddressSet private presales;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PresaleFactory__PresaleAlreadyExists();
    error PresaleFactory__OnlyOwner();
    error PresaleFactory__InvalidImplementation();
    error PresaleFactory__InvalidInput();
    error PresaleFactory__ExceedingMaxFee();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _uniswapV2Factory, address _uniswapV2Router, address _weth) {
        if (_uniswapV2Factory == address(0) || _uniswapV2Router == address(0) || weth == address(0)) {
            revert PresaleFactory__InvalidInput();
        }
        weth = _weth;
        owner = msg.sender;
        presaleImpl = address(new Presale());
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert PresaleFactory__OnlyOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice This function deploys a presale contract
     * @param _meta The metadata for the presale
     * @param _wlData The whitelist data for the presale
     * @param _tokenInfo The ERC20 token info for the presale
     * @param _presaleFee The fee the presale wants to take
     * @param _presaleFeeAddress The address where the team wants to receive fees
     * @param _ethPricePerToken Initial starting price of the presale
     * @param _startDate Start date for the presale
     * @param _duration Duration for the presale
     */
    function createPresale(
        PresaleMetadata calldata _meta,
        PresaleWhiteList calldata _wlData,
        PresaleTokenInfo calldata _tokenInfo,
        uint256 _presaleFee,
        address _presaleFeeAddress,
        uint256 _ethPricePerToken,
        uint32 _startDate,
        uint32 _duration
    ) external returns (Presale) {
        if (_presaleFee > MAX_FEE) revert PresaleFactory__ExceedingMaxFee();
        Presale presale = Presale(presaleImpl.clone());

        bool added = presales.add(address(presale));

        if (!added) revert PresaleFactory__PresaleAlreadyExists();

        PresaleParams memory params = PresaleParams(
            _ethPricePerToken,
            _meta,
            _wlData,
            _tokenInfo,
            msg.sender, // owner
            address(this), // factory
            _duration,
            _startDate,
            _presaleFee,
            _presaleFeeAddress
        );

        ///@dev Pull the initial tokens from deployer
        _tokenInfo.token.safeTransferFrom(msg.sender, address(this), _tokenInfo.hardCap);

        ///@dev Transfer the initial hardcap to the presale contract
        _tokenInfo.token.safeTransfer(address(presale), _tokenInfo.hardCap);

        presale.initialize(params);

        emit PresaleCreated(address(presale), msg.sender);

        return presale;
    }

    function isPresale(address _presale) external view returns (bool) {
        return presales.contains(_presale);
    }

    function presalesLength() external view returns (uint256) {
        return presales.length();
    }

    function getPresaleAtIndex(uint256 _index) external view returns (address) {
        return presales.at(_index);
    }

    /**
     *
     * @param _newImplementation The address of the new implementation
     * @notice This function updates the implementation for the clones
     * @dev Existing presales should not be affected by this, only newly created presales after the change should have the new implementation
     */
    function changeImplementation(address _newImplementation) external onlyOwner returns (address) {
        if (_newImplementation == address(0)) revert PresaleFactory__InvalidImplementation();

        presaleImpl = _newImplementation;

        emit ImplementationChanged(_newImplementation);

        return _newImplementation;
    }
}
