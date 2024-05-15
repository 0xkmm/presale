// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PresaleFactory} from "./PresaleFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {_safeDecimals} from "./utils/Helpers.sol";

import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "./interfaces/IUniswapV2.sol";

struct PresaleMetadata {
    ///@dev The name of the protocol
    string name;
    /// @dev Link for the website
    string website;
    /// @dev Base64 encoded url of the cover image
    string coverImage;
    /// @dev Maybe a ipfs link of the markdown or directly the markdown
    string description;
}

///@dev Presale params used when initializing the contract
struct PresaleParams {
    uint256 ethPricePerToken;
    PresaleMetadata meta;
    PresaleWhiteList whiteListData;
    PresaleTokenInfo presaleToken;
    address owner;
    address factory;
    uint32 duration;
    uint32 startDate;
    uint256 protocolFee;
    address protocolFeeAddress;
}

struct PresaleWhiteList {
    uint32 blockNumber;
    bytes32 root;
    uint256 minBalance;
}

/**
 * @param token  This is the ERC20 token registered for presale
 * @param decimals The decimals of the ERC20 token registered for presale
 * @param hardCap Maximum amount of tokens to be sold during the presale
 * @param totalSold Total tokens sold to users during the presale
 */
struct PresaleTokenInfo {
    IERC20 token;
    uint8 decimals;
    uint256 minBuy;
    uint256 maxBuy;
    uint256 hardCap;
    uint256 totalSold;
}

/**
 * @title Presale
 * @author kostadin-m
 * @notice This is the main presale contract where end users will interact with
 * @notice This will be the implementation contract used by PresaleFactory to deploy clones
 */
contract Presale is OwnableUpgradeable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokensPurchased(address indexed _token, address indexed buyer, uint256 amount);
    event TokensClaimed(address indexed _token, address indexed buyer, uint256 amount);
    event PresaleCreated(address indexed _presale);
    event EthPricePerTokenUpdated(address indexed _token, uint256 newEthPricePerToken);
    event WhitelistUpdated(uint256 wlBlockNumber, uint256 wlMinBalance, bytes32 wlRoot);
    event VestingStarted(address indexed pool, uint256 startDate, uint256 duration);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    struct UserRecord {
        uint256 purchasedAmount;
        uint256 investedNative;
        uint256 claimedAmount;
    }

    /// @dev The address of PresaleFactory
    PresaleFactory private factory;
    /// @dev This is the ERC20 token registered for the presale
    uint256 ethPricePerToken;
    /// @dev Fee that the protocol takes when the user buys into the token
    uint256 protocolFee;
    /// @dev The address that the team can receive the fees
    address protocolFeeAddress;
    ///@dev Total accumulated fees from the protocol
    uint256 accumulatedFees;
    /// @dev Metadata of the protocol (name, image, description)
    PresaleMetadata presaleMetaData;

    mapping(address => UserRecord) public userRecords;

    ///@dev Whitelist data
    PresaleWhiteList wl;

    ///@dev The start date of the presale
    uint32 startDate;
    ///@dev The end date of the presale calculated by startDate + duration
    uint32 endDate;

    ///@dev The drop rate indicates how much the price will drop every second for the duration of the presale
    uint32 dropRate = 1000;

    /// @dev This is the minimum the price can drop over time
    uint256 minPrice = 1e12;

    /// @dev Info for the ERC20 token
    PresaleTokenInfo presaleToken;

    /// @dev Track if the team terminated the protocol for users to withdraw their eth
    bool terminated;

    /// @dev This is the deadline the team has after the presale ends to create a liquidity pool
    uint256 DEADLINE_FOR_LP = 7 days;

    ///@dev The duration of the vesting period
    uint256 vestingDuration;
    ///@dev The start date of the vesting period )
    uint256 vestingStartDate;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Presale__NotPartOfWhiteList(address _presale);
    error Presale__PresaleNotStarted();
    error Presale__PresaleAlreadyEnded();
    error Presale__PresaleNotEnded();
    error Presale__PresaleAlreadyStarted();
    error Presale__InvalidInput();
    error Presale__InsufficientBalance();
    error Presale__NotTerminated();

    error Presale__ExceedsHardCap();
    error Presale__ProtocolTerminatedOrDeadlinePassed();
    error Presale__PresalePriceIsHigher();
    error Presale__UnableToApprove();
    error Presale__VestingAlreadyStarted();
    error Presale__VestingNotStarted();
    error Presale__CannotClaimMoreThanBalance();

    /*//////////////////////////////////////////////////////////////
                        INITIALIZERS/CONSTRUCTORS
    //////////////////////////////////////////////////////////////*/
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice This function acts as a constructor, since we are deploying via EIP1167 standard
     * @param _params Presale params
     */
    function initialize(PresaleParams calldata _params) external initializer {
        presaleToken = _params.presaleToken;
        presaleToken.decimals = _safeDecimals(address(_params.presaleToken.token));
        presaleMetaData = _params.meta;
        wl = _params.whiteListData;
        ethPricePerToken = _params.ethPricePerToken;
        protocolFee = _params.protocolFee;
        protocolFeeAddress = _params.protocolFeeAddress;
        startDate = _params.startDate;
        endDate = _params.startDate + _params.duration;
        factory = PresaleFactory(_params.factory);
        __Ownable_init_unchained(_params.owner);

        emit PresaleCreated(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _proof Proof to check agains the merkle tree root
     * @notice Verifies whether the sender is whitelisted, if not the function reverts
     */
    modifier isWhitelisted(bytes32[] calldata _proof) {
        if (!_verify(msg.sender, _proof)) revert Presale__NotPartOfWhiteList(address(this));
        _;
    }

    modifier isStarted() {
        if (block.timestamp < startDate) revert Presale__PresaleNotStarted();
        _;
    }

    modifier isNotStarted() {
        if (block.timestamp >= startDate) revert Presale__PresaleAlreadyStarted();
        _;
    }

    modifier isEnded() {
        if (block.timestamp > endDate) revert Presale__PresaleNotEnded();
        _;
    }

    modifier isNotEnded() {
        if (block.timestamp <= endDate) revert Presale__PresaleAlreadyEnded();
        _;
    }

    modifier onlyTerminated() {
        if (!terminated || block.timestamp < endDate + DEADLINE_FOR_LP) revert Presale__NotTerminated();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL PROTECTED
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _ethPricePerToken New price per token
     * @notice This function can only be called before actually starting the presale to avoid malicious teams from rug pulling
     */
    function updateEthPricePerToken(uint256 _ethPricePerToken) external onlyOwner isNotStarted {
        ethPricePerToken = _ethPricePerToken;

        emit EthPricePerTokenUpdated(address(presaleToken.token), _ethPricePerToken);
    }

    /**
     * @param _newRoot New merkle tree root for whitelisting.
     * @notice This function can be called only by the owner of the presale to update the root of the merkle tree.
     */
    function updateWhitelistRoot(bytes32 _newRoot) external onlyOwner {
        PresaleWhiteList memory _newWhiteList = PresaleWhiteList(uint32(block.timestamp), _newRoot, wl.minBalance);
        wl = _newWhiteList;
        emit WhitelistUpdated(block.timestamp, wl.minBalance, _newRoot);
    }
    /**
     * @notice This function can only be called by the owner after the presale ended
     * @notice If the team decides to terminate all of the invested eth can be withdrawn
     */

    function terminate() external onlyOwner isEnded {
        if (vestingStartDate == 0) revert Presale__VestingAlreadyStarted();
        terminated = true;
    }

    /**
     * @param _tokenHardCapIncrement Number to increment the current hardcap by
     * @notice This function pulls more tokens from the owner and increments the hardcap
     */
    function increaseHardCap(uint256 _tokenHardCapIncrement) external onlyOwner isNotEnded {
        presaleToken.token.safeTransferFrom(msg.sender, address(this), _tokenHardCapIncrement);

        presaleToken.hardCap += _tokenHardCapIncrement;
    }

    ///@notice This function is called by the owner, to pull the fees accumulated from the presale
    function pullFees() external onlyOwner {
        uint256 _totalFees = accumulatedFees;

        accumulatedFees = 0;

        payable(protocolFeeAddress).transfer(_totalFees);
    }

    /**
     * @notice This funciton is called by the owner to update any type of metadata
     * @param _meta The new metadata of the protocol
     */
    function updatePresaleMetaData(PresaleMetadata calldata _meta) external onlyOwner {
        if (keccak256(abi.encode(_meta.name)) == keccak256(abi.encode(""))) revert Presale__InvalidInput();
        if (keccak256(abi.encode(_meta.website)) == keccak256(abi.encode(""))) revert Presale__InvalidInput();
        if (keccak256(abi.encode(_meta.description)) == keccak256(abi.encode(""))) revert Presale__InvalidInput();
        if (keccak256(abi.encode(_meta.coverImage)) == keccak256(abi.encode(""))) revert Presale__InvalidInput();

        presaleMetaData = _meta;
    }

    /*//////////////////////////////////////////////////////////////
                               EXTERNAL 
    //////////////////////////////////////////////////////////////*/

    /**
     * @param proof Merkle tree proof to pass the whitelist test
     * @notice This is the main function the user has to invoke to buy tokens from the presale
     */
    function buyTokens(bytes32[] calldata proof) external payable isStarted isNotEnded isWhitelisted(proof) {
        if (msg.value == 0) revert Presale__InvalidInput();

        ///@dev Calculate the fee for the protocol
        uint256 feeAmount = (msg.value * protocolFee) / 1e18;
        uint256 amountAfterFee = msg.value - feeAmount;

        uint256 tokensToBuy = nativeToToken(amountAfterFee);

        if (tokensToBuy > presaleToken.maxBuy || tokensToBuy < presaleToken.minBuy) revert Presale__InvalidInput();
        if (tokensToBuy + presaleToken.totalSold > presaleToken.hardCap) revert Presale__ExceedsHardCap();

        emit TokensPurchased(address(presaleToken.token), msg.sender, tokensToBuy);

        presaleToken.totalSold += tokensToBuy;
        accumulatedFees += feeAmount;

        ///@dev If we reach the hardcap early we end the presale as all tokens are sold
        if (presaleToken.totalSold == presaleToken.hardCap) {
            endDate = uint32(block.timestamp);
        }

        userRecords[msg.sender].purchasedAmount += tokensToBuy;
        userRecords[msg.sender].investedNative += amountAfterFee;
    }

    ///@dev Should we even have this
    // function sellTokens(uint256 tokenAmount) external payable isStarted isNotEnded {
    //     if (userRecords[msg.sender].purchasedAmount < tokenAmount) revert Presale__InsufficientBalance();

    //     uint256 nativeToReceive = tokensToNative(tokenAmount);

    //     presaleToken.totalSold = presaleToken.totalSold - tokenAmount;
    //     userRecords[msg.sender].purchasedAmount -= tokenAmount;

    //     payable(msg.sender).transfer(nativeToReceive);
    // }

    /**
     * @notice This function can be called only after the team terminates the presale or after the deadline for lp passes
     */
    function withdrawNative() external onlyTerminated {
        uint256 totalInvestedNativeOfUser = userRecords[msg.sender].investedNative;
        if (totalInvestedNativeOfUser == 0) revert Presale__InsufficientBalance();

        userRecords[msg.sender].investedNative = 0;

        payable(msg.sender).transfer(totalInvestedNativeOfUser);
    }

    function createLPAndStartVesting(uint256 _vestingDuration, uint256 _deadline) external onlyOwner {
        ///@dev The team should not be able to start vesting, if the presale was terminated or the deadline passed.

        if (terminated || endDate + DEADLINE_FOR_LP < block.timestamp) {
            revert Presale__ProtocolTerminatedOrDeadlinePassed();
        }

        if (vestingDuration != 0) revert Presale__VestingAlreadyStarted();

        ///@dev Set the new vesting duration
        vestingDuration = _vestingDuration;
        vestingStartDate = block.timestamp;

        ///@dev The uniswap addreses are controlled by the factory, to avoid malicious address providing
        IUniswapV2Router02 uniswapRouter = IUniswapV2Router02(factory.uniswapV2Router());
        IUniswapV2Factory uniswapFactory = IUniswapV2Factory(factory.uniswapV2Factory());

        ///@dev Creating a liquidity pool from uniswapv2 factory

        // wake-disable-next-line
        address pair = uniswapFactory.createPair(address(presaleToken.token), factory.weth()); //@note - If the pair already exists the function will revert

        ///@dev Give allowance to the router
        presaleToken.token.safeIncreaseAllowance(address(uniswapRouter), presaleToken.totalSold);

        ///@dev Add liquidity via the uniswap router
        // wake-disable-next-line
        uniswapRouter.addLiquidityETH{value: address(this).balance}(
            address(presaleToken.token),
            presaleToken.totalSold,
            presaleToken.totalSold, // Should probably have less strict slippage
            address(this).balance, // Should probably have less strict slippage
            address(this),
            _deadline
        );

        ///@dev Get the total reserves after adding liquidity
        //        presale reserve    eth reserve
        (uint112 _reserve0, uint112 _reserve1,) = IUniswapV2Pair(pair).getReserves();

        ///@dev Check the price of presaleToken by checking the amountOut with (amount=1, reserveIn=Presale token, reserveOut=WETH)
        uint256 price = uniswapRouter.getAmountOut(1, _reserve0, _reserve1);

        ///@dev If the price is less, than the current price revert
        if (price < _nativePerToken()) revert Presale__PresalePriceIsHigher();

        emit VestingStarted(pair, block.timestamp, _vestingDuration);
    }
    /**
     * @param _address The address of the user to which we want to check the claimable amount
     * @notice This function returns the claimable amount of the user based on his token balance and the time passed since start of vesting
     */

    function claimableAmount(address _address) public view returns (uint256) {
        ///@dev If more time passed than the vestingDuration, just use the duration to unlock the full amounts of tokens
        uint256 timePassed =
            vestingStartDate + vestingDuration < block.timestamp ? vestingDuration : block.timestamp - vestingStartDate;

        ///@dev Get the non-claimed tokens
        uint256 nonClaimedAmount = userRecords[_address].purchasedAmount - userRecords[_address].claimedAmount;

        ///@dev Calculate based on users current amount of tokens with the formula (userTokens * amount passed since start of vesting ) / vestingDuration
        return (nonClaimedAmount * timePassed) / vestingDuration;
    }

    /**
     * @notice This function can only be called after the presale ended and the team provided LP
     */
    function claimTokens() external isEnded {
        ///@dev Users should only be able to claim after vesting is started
        if (vestingStartDate == 0) revert Presale__VestingNotStarted();

        ///@dev Get the claimed amount
        uint256 amountToClaim = claimableAmount(msg.sender);

        /// @dev This shouldn't be possible, but just in case
        if (userRecords[msg.sender].claimedAmount + amountToClaim > userRecords[msg.sender].purchasedAmount) {
            revert Presale__CannotClaimMoreThanBalance();
        }

        emit TokensClaimed(address(presaleToken.token), msg.sender, amountToClaim);

        ///@dev Update user's claimedAmount
        userRecords[msg.sender].claimedAmount += amountToClaim;

        ///@dev -> Transfer the tokens to claim
        presaleToken.token.safeTransfer(msg.sender, amountToClaim);
    }

    /*//////////////////////////////////////////////////////////////            
                            PUBLIC-VIEW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the duration for the presale
     */
    function getDuration() public view returns (uint32) {
        return endDate - startDate;
    }

    /**
     * @param ethAmount Amount of eth to convert to tokens depending on the price
     * @notice This function calculates how much tokens to send to the user
     */
    function nativeToToken(uint256 ethAmount) public view returns (uint256) {
        return (ethAmount * (10 ** presaleToken.decimals)) / _nativePerToken();
    }

    /**
     * @param tokensAmount Amount of tokens to convert to eth depending on the price
     */
    function tokensToNative(uint256 tokensAmount) public view returns (uint256) {
        return (tokensAmount * _nativePerToken()) / (10 ** presaleToken.decimals);
    }

    /*//////////////////////////////////////////////////////////////            
                            INTERNAL/PRIVATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Function to verify the user's eligibility to participate in the presale using merkle tree
     * @dev Merkle leaf should be keccak256(abi.encode(wallet, chainId, presaleContractAddress))
     * @param _wallet Address of the user
     * @param _proof Merkle tree proof of the user
     */
    function _verify(address _wallet, bytes32[] calldata _proof) internal view returns (bool) {
        return (MerkleProof.verify(_proof, wl.root, keccak256(abi.encode(_wallet, block.chainid, address(this)))));
    }

    /**
     * @dev This function calculates the native price of one presale token
     * @notice Price decreases overtime
     * @notice Price increases as the demand for the presale grows
     */
    function _nativePerToken() internal view returns (uint256) {
        uint256 tempHardCap = presaleToken.hardCap;

        /**
         * @dev Calculating the price depending on how much tokens are bought
         * @notice The more tokens are sold to the users, the bigger the price and vice versa
         */
        uint256 basePrice = ethPricePerToken * (tempHardCap + presaleToken.totalSold) / tempHardCap;

        /// @dev If the presale ended return the price based on the whole duration of the presale
        uint256 timeElapsed = block.timestamp > endDate ? getDuration() : block.timestamp - startDate;
        uint256 discount = dropRate * timeElapsed;
        /// @dev Decrease the price overtime with dropRate * seconds since start
        uint256 discountedPrice = basePrice - discount;

        return discountedPrice > minPrice ? discountedPrice : minPrice;
    }
}
