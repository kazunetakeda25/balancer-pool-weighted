// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/ReentrancyGuard.sol";
import "@balancer-labs/v2-solidity-utils/contracts/helpers/ERC20Helpers.sol";
import "@balancer-labs/v2-solidity-utils/contracts/helpers/WordCodec.sol";
import "@balancer-labs/v2-solidity-utils/contracts/helpers/ArrayHelpers.sol";

import "@balancer-labs/v2-pool-utils/contracts/ProtocolFeeCache.sol";

import "../lib/GradualValueChange.sol";
import "../lib/WeightCompression.sol";

import "../BaseWeightedPool.sol";
import "../WeightedPoolUserData.sol";

/**
 * @dev Weighted Pool with mutable tokens and weights, designed to be used in conjunction with a pool controller
 * contract (as the owner, containing any specific business logic). Since the pool itself permits "dangerous"
 * operations, it should never be deployed with an EOA as the owner.
 *
 * Pool controllers can add functionality: for example, allow the effective "owner" to be transferred to another
 * address. (The actual pool owner is still immutable, set to the pool controller contract.) Another pool owner
 * might allow fine-grained permissioning of protected operations: perhaps a multisig can add/remove tokens, but
 * a third-party EOA is allowed to set the swap fees.
 *
 * Pool controllers might also impose limits on functionality so that operations that might endanger LPs can be
 * performed more safely. For instance, the pool by itself places no restrictions on the duration of a gradual
 * weight change, but a pool controller might restrict this in various ways, from a simple minimum duration,
 * to a more complex rate limit.
 *
 * Pool controllers can also serve as intermediate contracts to hold tokens, deploy timelocks, consult with other
 * protocols or on-chain oracles, or bundle several operations into one transaction that re-entrancy protection
 * would prevent initiating from the pool contract.
 *
 * Managed Pools and their controllers are designed to support many asset management use cases, including: large
 * token counts, rebalancing through token changes, gradual weight or fee updates, fine-grained control of
 * protocol and management fees, allowlisting of LPs, and more.
 */
contract ManagedPool is BaseWeightedPool, ProtocolFeeCache, ReentrancyGuard {
    // ManagedPool weights and swap fees can change over time: these periods are expected to be long enough (e.g. days)
    // that any timestamp manipulation would achieve very little.
    // solhint-disable not-rely-on-time

    using FixedPoint for uint256;
    using WordCodec for bytes32;
    using WeightCompression for uint256;
    using WeightedPoolUserData for bytes;

    // State variables

    // The upper bound is WeightedMath.MAX_WEIGHTED_TOKENS, but this is constrained by other factors, such as Pool
    // creation gas consumption.
    uint256 private constant _MAX_MANAGED_TOKENS = 50;

    uint256 private constant _MAX_MANAGEMENT_SWAP_FEE_PERCENTAGE = 1e18; // 100%

    uint256 private constant _MAX_MANAGEMENT_AUM_FEE_PERCENTAGE = 1e17; // 10%

    // Use the _miscData slot in BasePool
    // The first 64 bits are reserved for the swap fee
    //
    // Store non-token-based values:
    // Start/end timestamps for gradual weight update
    // Cache total tokens
    // [ 64 bits  |  1 bit  | 31 bits |   1 bit   |  31 bits  |  64 bits |  32 bits |  32 bits  ]
    // [ swap fee | LP flag | fee end | swap flag | fee start | end swap | end wgt  | start wgt ]
    // |MSB                                                                                  LSB|
    uint256 private constant _WEIGHT_START_TIME_OFFSET = 0;
    uint256 private constant _WEIGHT_END_TIME_OFFSET = 32;
    uint256 private constant _END_SWAP_FEE_PERCENTAGE_OFFSET = 64;
    uint256 private constant _FEE_START_TIME_OFFSET = 128;
    uint256 private constant _SWAP_ENABLED_OFFSET = 159;
    uint256 private constant _FEE_END_TIME_OFFSET = 160;
    uint256 private constant _MUST_ALLOWLIST_LPS_OFFSET = 191;
    uint256 private constant _SWAP_FEE_PERCENTAGE_OFFSET = 192;

    // Store scaling factor and start/end denormalized weights for each token
    // Mapping should be more efficient than trying to compress it further
    // [ 123 bits |  5 bits  |  64 bits   |   64 bits    |
    // [ unused   | decimals | end denorm | start denorm |
    // |MSB                                           LSB|
    mapping(IERC20 => bytes32) private _tokenState;

    // Denormalized weights are stored using the WeightCompression library as a percentage of the maximum absolute
    // denormalized weight: independent of the current _denormWeightSum, which avoids having to recompute the denorm
    // weights as the sum changes.
    uint256 private constant _MAX_DENORM_WEIGHT = 1e22; // FP 10,000

    uint256 private constant _START_DENORM_WEIGHT_OFFSET = 0;
    uint256 private constant _END_DENORM_WEIGHT_OFFSET = 64;
    uint256 private constant _DECIMAL_DIFF_OFFSET = 128;

    // If mustAllowlistLPs is enabled, this is the list of addresses allowed to join the pool
    mapping(address => bool) private _allowedAddresses;

    // We need to work with normalized weights (i.e. they should add up to 100%), but storing normalized weights
    // would require updating all weights whenever one of them changes, for example in an add or remove token
    // operation. Instead, we keep track of the sum of all denormalized weights, and dynamically normalize them
    // for I/O by multiplying or dividing by the `_denormWeightSum`.
    //
    // In this contract, "weights" mean normalized weights, and "denormWeights" refer to how they are stored internally.
    uint256 private _denormWeightSum;

    // Percentage of swap fees that are allocated to the Pool owner, after protocol fees
    uint256 private _managementSwapFeePercentage;

    // Store the token count locally (can change if tokens are added or removed)
    uint256 private _totalTokensCache;

    // Percentage of the pool's TVL to pay as management AUM fees over the course of a year.
    uint256 private _managementAumFeePercentage;

    // Timestamp of the most recent collection of management AUM fees.
    // Note that this is only initialized the first times fees are collected.
    uint256 private _lastAumFeeCollectionTimestamp;

    // Event declarations

    event GradualWeightUpdateScheduled(
        uint256 startTime,
        uint256 endTime,
        uint256[] startWeights,
        uint256[] endWeights
    );
    event SwapEnabledSet(bool swapEnabled);
    event MustAllowlistLPsSet(bool mustAllowlistLPs);
    event ManagementSwapFeePercentageChanged(uint256 managementSwapFeePercentage);
    event ManagementAumFeePercentageChanged(uint256 managementAumFeePercentage);
    event ManagementAumFeeCollected(uint256 bptAmount);
    event AllowlistAddressAdded(address indexed member);
    event AllowlistAddressRemoved(address indexed member);
    event GradualSwapFeeUpdateScheduled(
        uint256 startTime,
        uint256 endTime,
        uint256 startSwapFeePercentage,
        uint256 endSwapFeePercentage
    );
    event TokenRemoved(IERC20 indexed token, uint256 tokenAmountOut);

    struct NewPoolParams {
        string name;
        string symbol;
        IERC20[] tokens;
        uint256[] normalizedWeights;
        address[] assetManagers;
        uint256 swapFeePercentage;
        bool swapEnabledOnStart;
        bool mustAllowlistLPs;
        uint256 protocolSwapFeePercentage;
        uint256 managementSwapFeePercentage;
        uint256 managementAumFeePercentage;
    }

    constructor(
        NewPoolParams memory params,
        IVault vault,
        address owner,
        uint256 pauseWindowDuration,
        uint256 bufferPeriodDuration
    )
        BaseWeightedPool(
            vault,
            params.name,
            params.symbol,
            params.tokens,
            params.assetManagers,
            params.swapFeePercentage,
            pauseWindowDuration,
            bufferPeriodDuration,
            owner
        )
        ProtocolFeeCache(vault, params.protocolSwapFeePercentage)
    {
        uint256 totalTokens = params.tokens.length;
        InputHelpers.ensureInputLengthMatch(totalTokens, params.normalizedWeights.length, params.assetManagers.length);

        _totalTokensCache = totalTokens;

        // Validate and set initial fees
        _setManagementSwapFeePercentage(params.managementSwapFeePercentage);

        _setManagementAumFeePercentage(params.managementAumFeePercentage);

        // Initialize the denorm weight sum to the initial normalized weight sum of ONE
        _denormWeightSum = FixedPoint.ONE;

        uint256 currentTime = block.timestamp;
        _startGradualWeightChange(
            currentTime,
            currentTime,
            params.normalizedWeights,
            params.normalizedWeights,
            params.tokens
        );

        _startGradualSwapFeeChange(currentTime, currentTime, params.swapFeePercentage, params.swapFeePercentage);

        // If false, the pool will start in the disabled state (prevents front-running the enable swaps transaction).
        _setSwapEnabled(params.swapEnabledOnStart);

        // If true, only addresses on the manager-controlled allowlist may join the pool.
        _setMustAllowlistLPs(params.mustAllowlistLPs);
    }

    /**
     * @dev Returns true if swaps are enabled.
     */
    function getSwapEnabled() public view returns (bool) {
        return _getMiscData().decodeBool(_SWAP_ENABLED_OFFSET);
    }

    /**
     * @dev Returns true if the allowlist for LPs is enabled.
     */
    function getMustAllowlistLPs() public view returns (bool) {
        return _getMiscData().decodeBool(_MUST_ALLOWLIST_LPS_OFFSET);
    }

    /**
     * @dev Verifies that a given address is allowed to hold tokens.
     */
    function isAllowedAddress(address member) public view returns (bool) {
        return !getMustAllowlistLPs() || _allowedAddresses[member];
    }

    /**
     * @dev Returns the management swap fee percentage as a 18-decimals fixed point number.
     */
    function getManagementSwapFeePercentage() public view returns (uint256) {
        return _managementSwapFeePercentage;
    }

    function getSwapFeePercentage() public view virtual override returns (uint256) {
        // Load current pool state from storage
        bytes32 poolState = _getMiscData();

        uint256 startSwapFeePercentage = poolState.decodeUint64(_SWAP_FEE_PERCENTAGE_OFFSET);
        uint256 endSwapFeePercentage = poolState.decodeUint64(_END_SWAP_FEE_PERCENTAGE_OFFSET);
        uint256 startTime = poolState.decodeUint31(_FEE_START_TIME_OFFSET);
        uint256 endTime = poolState.decodeUint31(_FEE_END_TIME_OFFSET);

        return
            GradualValueChange.getInterpolatedValue(startSwapFeePercentage, endSwapFeePercentage, startTime, endTime);
    }

    /**
     * @dev Return start/end times and swap fee percentages. The current swap fee
     * can be retrieved via `getSwapFeePercentage()`.
     */
    function getGradualSwapFeeUpdateParams()
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256 startSwapFeePercentage,
            uint256 endSwapFeePercentage
        )
    {
        // Load current pool state from storage
        bytes32 poolState = _getMiscData();

        startTime = poolState.decodeUint31(_FEE_START_TIME_OFFSET);
        endTime = poolState.decodeUint31(_FEE_END_TIME_OFFSET);
        startSwapFeePercentage = poolState.decodeUint64(_SWAP_FEE_PERCENTAGE_OFFSET);
        endSwapFeePercentage = poolState.decodeUint64(_END_SWAP_FEE_PERCENTAGE_OFFSET);
    }

    function _setSwapFeePercentage(uint256 swapFeePercentage) internal virtual override {
        // Do not allow setting if there is an ongoing fee change
        uint256 currentTime = block.timestamp;
        bytes32 poolState = _getMiscData();

        uint256 startTime = poolState.decodeUint31(_FEE_START_TIME_OFFSET);
        uint256 endTime = poolState.decodeUint31(_FEE_END_TIME_OFFSET);

        if (currentTime < startTime) {
            _revert(Errors.SET_SWAP_FEE_PENDING_FEE_CHANGE);
        } else if (currentTime < endTime) {
            _revert(Errors.SET_SWAP_FEE_DURING_FEE_CHANGE);
        }

        _setSwapFeeData(currentTime, currentTime, swapFeePercentage);

        super._setSwapFeePercentage(swapFeePercentage);
    }

    /**
     * @dev Returns the management AUM fee percentage as a 18-decimals fixed point number.
     */
    function getManagementAumFeePercentage() public view returns (uint256) {
        return _managementAumFeePercentage;
    }

    /**
     * @dev Return start time, end time, and endWeights as an array.
     * Current weights should be retrieved via `getNormalizedWeights()`.
     */
    function getGradualWeightUpdateParams()
        external
        view
        returns (
            uint256 startTime,
            uint256 endTime,
            uint256[] memory endWeights
        )
    {
        // Load current pool state from storage
        bytes32 poolState = _getMiscData();

        startTime = poolState.decodeUint32(_WEIGHT_START_TIME_OFFSET);
        endTime = poolState.decodeUint32(_WEIGHT_END_TIME_OFFSET);

        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());
        uint256 totalTokens = _getTotalTokens();

        endWeights = new uint256[](totalTokens);

        for (uint256 i = 0; i < totalTokens; i++) {
            endWeights[i] = _normalizeWeight(
                _tokenState[tokens[i]].decodeUint64(_END_DENORM_WEIGHT_OFFSET).uncompress64(_MAX_DENORM_WEIGHT)
            );
        }
    }

    /**
     * @dev Returns the normalization factor, which is used to efficiently scale weights when adding and removing
     * tokens. This value is an internal implementation detail and typically useless from the outside.
     */
    function getDenormalizedWeightSum() public view returns (uint256) {
        return _denormWeightSum;
    }

    function _getMaxTokens() internal pure virtual override returns (uint256) {
        return _MAX_MANAGED_TOKENS;
    }

    function _getTotalTokens() internal view virtual override returns (uint256) {
        return _totalTokensCache;
    }

    /**
     * @dev Schedule a gradual weight change, from the current weights to the given endWeights,
     * over startTime to endTime.
     */
    function updateWeightsGradually(
        uint256 startTime,
        uint256 endTime,
        uint256[] memory endWeights
    ) external authenticate whenNotPaused nonReentrant {
        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());

        InputHelpers.ensureInputLengthMatch(tokens.length, endWeights.length);

        startTime = GradualValueChange.resolveStartTime(startTime, endTime);

        _startGradualWeightChange(startTime, endTime, _getNormalizedWeights(), endWeights, tokens);
    }

    /**
     * @dev Schedule a gradual swap fee change, from the starting value (which may or may not be the current
     * value) to the given ending fee percentage, over startTime to endTime. Calling this with a starting
     * value avoids requiring an explicit external `setSwapFeePercentage` call.
     */
    function updateSwapFeeGradually(
        uint256 startTime,
        uint256 endTime,
        uint256 startSwapFeePercentage,
        uint256 endSwapFeePercentage
    ) external authenticate whenNotPaused nonReentrant {
        _validateSwapFeePercentage(startSwapFeePercentage);
        _validateSwapFeePercentage(endSwapFeePercentage);

        startTime = GradualValueChange.resolveStartTime(startTime, endTime);

        _startGradualSwapFeeChange(startTime, endTime, startSwapFeePercentage, endSwapFeePercentage);
    }

    function _validateSwapFeePercentage(uint256 swapFeePercentage) private pure {
        _require(swapFeePercentage >= _getMinSwapFeePercentage(), Errors.MIN_SWAP_FEE_PERCENTAGE);
        _require(swapFeePercentage <= _getMaxSwapFeePercentage(), Errors.MAX_SWAP_FEE_PERCENTAGE);
    }

    /**
     * @dev Adds an address to the allowlist.
     */
    function addAllowedAddress(address member) external authenticate whenNotPaused {
        _require(getMustAllowlistLPs(), Errors.UNAUTHORIZED_OPERATION);
        _require(!_allowedAddresses[member], Errors.ADDRESS_ALREADY_ALLOWLISTED);

        _allowedAddresses[member] = true;
        emit AllowlistAddressAdded(member);
    }

    /**
     * @dev Removes an address from the allowlist.
     */
    function removeAllowedAddress(address member) external authenticate whenNotPaused {
        _require(_allowedAddresses[member], Errors.ADDRESS_NOT_ALLOWLISTED);

        delete _allowedAddresses[member];
        emit AllowlistAddressRemoved(member);
    }

    /**
     * @dev Can enable/disable the LP allowlist. Note that any addresses added to the allowlist
     * will be retained if the allowlist is toggled off and back on again.
     */
    function setMustAllowlistLPs(bool mustAllowlistLPs) external authenticate whenNotPaused {
        _setMustAllowlistLPs(mustAllowlistLPs);
    }

    function _setMustAllowlistLPs(bool mustAllowlistLPs) private {
        _setMiscData(_getMiscData().insertBool(mustAllowlistLPs, _MUST_ALLOWLIST_LPS_OFFSET));

        emit MustAllowlistLPsSet(mustAllowlistLPs);
    }

    /**
     * @dev Enable/disable trading
     */
    function setSwapEnabled(bool swapEnabled) external authenticate whenNotPaused {
        _setSwapEnabled(swapEnabled);
    }

    function _setSwapEnabled(bool swapEnabled) private {
        _setMiscData(_getMiscData().insertBool(swapEnabled, _SWAP_ENABLED_OFFSET));

        emit SwapEnabledSet(swapEnabled);
    }

    /**
     * @notice Removes a token from the Pool's list of tradeable tokens.
     * @dev Removes a token from the Pool's composition, withdrawing all funds from the Vault and sending them to
     * `recipient`, and adjusting the weights of all other tokens.
     *
     * Tokens can only be removed if the Pool has more than 2 tokens, as it can never have fewer than 2. Token removal
     * is also forbidden during a weight change, or if one is scheduled to happen in the future.
     *
     * The caller may additionally pass a non-zero `burnAmount` to have some of their BPT be burned, which might be
     * useful in some scenarios to account for the fact that the Pool now has fewer tokens.
     * @param token - The ERC20 token to be removed from the Pool.
     * @param recipient - The address which is to receive the Pool's balance of `token` after it is removed.
     * @param burnAmount - An amount of BPT which is to be burnt as a result of removing `token` from the Pool.
     * @return The amount of tokens the Pool held, sent to `recipient`.
     */
    function removeToken(
        IERC20 token,
        address recipient,
        uint256 burnAmount,
        uint256 minAmountOut
    ) external authenticate nonReentrant whenNotPaused returns (uint256) {
        // We require the pool to be initialized (shown by the total supply being nonzero) in order to remove a token,
        // maintaining the behaviour that no exits can occur before the pool has been initialized.
        // This prevents the AUM fee calculation being triggered before the pool contains any assets.
        _require(totalSupply() > 0, Errors.UNINITIALIZED);

        // Exit the pool, returning the full balance of the token to the recipient
        (IERC20[] memory tokens, uint256[] memory unscaledBalances, ) = getVault().getPoolTokens(getPoolId());
        _require(tokens.length > 2, Errors.MIN_TOKENS);

        // Tokens cannot be removed during or before a weight change to reduce complexity of weight interactions
        _ensureNoWeightChange();

        // Reverts if token does not exist in pool.
        uint256 tokenIndex = _tokenAddressToIndex(tokens, token);
        uint256 tokenBalance = unscaledBalances[tokenIndex];
        uint256 tokenNormalizedWeight = _getNormalizedWeight(token);

        // We first perform a special exit operation at the Vault, which will withdraw the entire tokenBalance from it.
        // Only the Pool itself is authorized to initiate such an exit.
        uint256[] memory minAmountsOut = new uint256[](tokens.length);
        minAmountsOut[tokenIndex] = minAmountOut;

        // Note that this exit will trigger a collection of the AUM fees payable up to now.
        getVault().exitPool(
            getPoolId(),
            address(this),
            payable(recipient),
            IVault.ExitPoolRequest({
                assets: _asIAsset(tokens),
                minAmountsOut: minAmountsOut,
                userData: abi.encode(WeightedPoolUserData.ExitKind.REMOVE_TOKEN, tokenIndex),
                toInternalBalance: false
            })
        );

        // The Pool is now in an invalid state, since one of its tokens has a balance of zero (making the invariant also
        // zero). We immediately deregister the emptied-out token to restore a valid state.
        // Since all non-view Vault functions are non-reentrant, and we make no external calls between the two Vault
        // calls (`exitPool` and `deregisterTokens`), it is impossible for any actor to interact with the Pool while it
        // is in this inconsistent state (except for view calls).

        IERC20[] memory tokensToRemove = new IERC20[](1);
        tokensToRemove[0] = token;
        getVault().deregisterTokens(getPoolId(), tokensToRemove);

        // Now all we need to do is delete the removed token's entry and update the sum of denormalized weights to scale
        // all other token weights accordingly.
        // Clean up data structures and update the token count
        delete _tokenState[token];
        _denormWeightSum -= _denormalizeWeight(tokenNormalizedWeight);

        _totalTokensCache = tokens.length - 1;

        if (burnAmount > 0) {
            _burnPoolTokens(msg.sender, burnAmount);
        }

        emit TokenRemoved(token, tokenBalance);

        return tokenBalance;
    }

    function _ensureNoWeightChange() private view {
        uint256 currentTime = block.timestamp;
        bytes32 poolState = _getMiscData();

        uint256 startTime = poolState.decodeUint32(_WEIGHT_START_TIME_OFFSET);
        uint256 endTime = poolState.decodeUint32(_WEIGHT_END_TIME_OFFSET);

        if (currentTime < startTime) {
            _revert(Errors.CHANGE_TOKENS_PENDING_WEIGHT_CHANGE);
        } else if (currentTime < endTime) {
            _revert(Errors.CHANGE_TOKENS_DURING_WEIGHT_CHANGE);
        }
    }

    /**
     * @dev Set the management fee percentage
     */
    function setManagementSwapFeePercentage(uint256 managementSwapFeePercentage) external authenticate whenNotPaused {
        _setManagementSwapFeePercentage(managementSwapFeePercentage);
    }

    function _setManagementSwapFeePercentage(uint256 managementSwapFeePercentage) private {
        _require(
            managementSwapFeePercentage <= _MAX_MANAGEMENT_SWAP_FEE_PERCENTAGE,
            Errors.MAX_MANAGEMENT_SWAP_FEE_PERCENTAGE
        );

        _managementSwapFeePercentage = managementSwapFeePercentage;
        emit ManagementSwapFeePercentageChanged(managementSwapFeePercentage);
    }

    /**
     * @notice Sets the yearly percentage AUM management fee which is payable to the pool manager.
     * @dev Attempting to collect AUM fees in excesss of 10% will result in this function reverting.
     */
    function setManagementAumFeePercentage(uint256 managementAumFeePercentage)
        external
        authenticate
        whenNotPaused
        returns (uint256 amount)
    {
        // We want to avoid a pool manager being able to retroactively increase the amount of AUM fees payable.
        // We then perform a collection before updating the fee percentage to prevent this.
        // This is only necessary if the pool has been initialized (which is shown by the total supply being nonzero).
        if (totalSupply() > 0) {
            amount = _collectAumManagementFees();
        }

        _setManagementAumFeePercentage(managementAumFeePercentage);
    }

    function _setManagementAumFeePercentage(uint256 managementAumFeePercentage) private {
        _require(
            managementAumFeePercentage <= _MAX_MANAGEMENT_AUM_FEE_PERCENTAGE,
            Errors.MAX_MANAGEMENT_AUM_FEE_PERCENTAGE
        );

        _managementAumFeePercentage = managementAumFeePercentage;
        emit ManagementAumFeePercentageChanged(managementAumFeePercentage);
    }

    /**
     * @notice Collect any accrued AUM fees and send them to the pool manager.
     * @dev This can be called by anyone to collect accrued AUM fees - and will be called automatically on
     * joins and exits.
     */
    function collectAumManagementFees() external returns (uint256) {
        // It only makes sense to collect AUM fees after the pool is initialized (as before then the AUM is zero).
        // We can query if the pool is initialized by checking for a nonzero total supply.
        // Reverting here prevents zero value AUM fee collections causing bogus events.
        if (totalSupply() == 0) _revert(Errors.UNINITIALIZED);

        return _collectAumManagementFees();
    }

    function _scalingFactor(IERC20 token) internal view virtual override returns (uint256) {
        return _readScalingFactor(_getTokenData(token));
    }

    function _scalingFactors() internal view virtual override returns (uint256[] memory scalingFactors) {
        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());
        uint256 numTokens = tokens.length;

        scalingFactors = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            scalingFactors[i] = _readScalingFactor(_tokenState[tokens[i]]);
        }
    }

    function _getNormalizedWeight(IERC20 token) internal view override returns (uint256) {
        bytes32 tokenData = _getTokenData(token);
        uint256 startWeight = tokenData.decodeUint64(_START_DENORM_WEIGHT_OFFSET).uncompress64(_MAX_DENORM_WEIGHT);
        uint256 endWeight = tokenData.decodeUint64(_END_DENORM_WEIGHT_OFFSET).uncompress64(_MAX_DENORM_WEIGHT);

        bytes32 poolState = _getMiscData();
        uint256 startTime = poolState.decodeUint32(_WEIGHT_START_TIME_OFFSET);
        uint256 endTime = poolState.decodeUint32(_WEIGHT_END_TIME_OFFSET);

        return _normalizeWeight(GradualValueChange.getInterpolatedValue(startWeight, endWeight, startTime, endTime));
    }

    function _getNormalizedWeights() internal view override returns (uint256[] memory normalizedWeights) {
        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(getPoolId());
        uint256 numTokens = tokens.length;

        normalizedWeights = new uint256[](numTokens);

        bytes32 poolState = _getMiscData();
        uint256 startTime = poolState.decodeUint32(_WEIGHT_START_TIME_OFFSET);
        uint256 endTime = poolState.decodeUint32(_WEIGHT_END_TIME_OFFSET);

        for (uint256 i = 0; i < numTokens; i++) {
            bytes32 tokenData = _tokenState[tokens[i]];
            uint256 startWeight = tokenData.decodeUint64(_START_DENORM_WEIGHT_OFFSET).uncompress64(_MAX_DENORM_WEIGHT);
            uint256 endWeight = tokenData.decodeUint64(_END_DENORM_WEIGHT_OFFSET).uncompress64(_MAX_DENORM_WEIGHT);

            normalizedWeights[i] = _normalizeWeight(
                GradualValueChange.getInterpolatedValue(startWeight, endWeight, startTime, endTime)
            );
        }
    }

    // Swap overrides - revert unless swaps are enabled

    function _onSwapGivenIn(
        SwapRequest memory swapRequest,
        uint256 currentBalanceTokenIn,
        uint256 currentBalanceTokenOut
    ) internal virtual override returns (uint256) {
        _require(getSwapEnabled(), Errors.SWAPS_DISABLED);

        (uint256[] memory normalizedWeights, uint256[] memory preSwapBalances) = _getWeightsAndPreSwapBalances(
            swapRequest,
            currentBalanceTokenIn,
            currentBalanceTokenOut
        );

        // balances (and swapRequest.amount) are already upscaled by BaseMinimalSwapInfoPool.onSwap
        uint256 amountOut = super._onSwapGivenIn(swapRequest, currentBalanceTokenIn, currentBalanceTokenOut);

        uint256[] memory postSwapBalances = ArrayHelpers.arrayFill(
            currentBalanceTokenIn.add(_addSwapFeeAmount(swapRequest.amount)),
            currentBalanceTokenOut.sub(amountOut)
        );

        _payProtocolAndManagementFees(normalizedWeights, preSwapBalances, postSwapBalances);

        return amountOut;
    }

    function _onSwapGivenOut(
        SwapRequest memory swapRequest,
        uint256 currentBalanceTokenIn,
        uint256 currentBalanceTokenOut
    ) internal virtual override returns (uint256) {
        _require(getSwapEnabled(), Errors.SWAPS_DISABLED);

        (uint256[] memory normalizedWeights, uint256[] memory preSwapBalances) = _getWeightsAndPreSwapBalances(
            swapRequest,
            currentBalanceTokenIn,
            currentBalanceTokenOut
        );

        // balances (and swapRequest.amount) are already upscaled by BaseMinimalSwapInfoPool.onSwap
        uint256 amountIn = super._onSwapGivenOut(swapRequest, currentBalanceTokenIn, currentBalanceTokenOut);

        uint256[] memory postSwapBalances = ArrayHelpers.arrayFill(
            currentBalanceTokenIn.add(_addSwapFeeAmount(amountIn)),
            currentBalanceTokenOut.sub(swapRequest.amount)
        );

        _payProtocolAndManagementFees(normalizedWeights, preSwapBalances, postSwapBalances);

        return amountIn;
    }

    function _getWeightsAndPreSwapBalances(
        SwapRequest memory swapRequest,
        uint256 currentBalanceTokenIn,
        uint256 currentBalanceTokenOut
    ) private view returns (uint256[] memory, uint256[] memory) {
        uint256[] memory normalizedWeights = ArrayHelpers.arrayFill(
            _getNormalizedWeight(swapRequest.tokenIn),
            _getNormalizedWeight(swapRequest.tokenOut)
        );

        uint256[] memory preSwapBalances = ArrayHelpers.arrayFill(currentBalanceTokenIn, currentBalanceTokenOut);

        return (normalizedWeights, preSwapBalances);
    }

    function _payProtocolAndManagementFees(
        uint256[] memory normalizedWeights,
        uint256[] memory preSwapBalances,
        uint256[] memory postSwapBalances
    ) private {
        // Calculate total BPT for the protocol and management fee
        // The management fee percentage applies to the remainder,
        // after the protocol fee has been collected.
        // So totalFee = protocolFee + (1 - protocolFee) * managementFee
        uint256 protocolSwapFeePercentage = getProtocolSwapFeePercentageCache();
        uint256 managementSwapFeePercentage = _managementSwapFeePercentage;

        if (protocolSwapFeePercentage == 0 && managementSwapFeePercentage == 0) {
            return;
        }

        // Fees are bounded, so we don't need checked math
        uint256 totalFeePercentage = protocolSwapFeePercentage +
            (FixedPoint.ONE - protocolSwapFeePercentage).mulDown(managementSwapFeePercentage);

        // No other balances are changing, so the other terms in the invariant will cancel out
        // when computing the ratio. So this partial invariant calculation is sufficient
        uint256 totalBptAmount = WeightedMath._calcDueProtocolSwapFeeBptAmount(
            totalSupply(),
            WeightedMath._calculateInvariant(normalizedWeights, preSwapBalances),
            WeightedMath._calculateInvariant(normalizedWeights, postSwapBalances),
            totalFeePercentage
        );

        // Calculate the portion of the total fee due the protocol
        // If the protocol fee were 30% and the manager fee 10%, the protocol would take 30% first.
        // Then the manager would take 10% of the remaining 70% (that is, 7%), for a total fee of 37%
        // The protocol would then earn 0.3/0.37 ~=81% of the total fee,
        // and the manager would get 0.1/0.75 ~=13%.
        uint256 protocolBptAmount = totalBptAmount.mulUp(protocolSwapFeePercentage.divUp(totalFeePercentage));

        if (protocolBptAmount > 0) {
            _payProtocolFees(protocolBptAmount);
        }

        // Pay the remainder in management fees
        // This goes to the controller, which needs to be able to withdraw them
        if (managementSwapFeePercentage > 0) {
            _mintPoolTokens(getOwner(), totalBptAmount.sub(protocolBptAmount));
        }
    }

    // Join/Exit overrides

    function _doJoin(
        address sender,
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory scalingFactors,
        bytes memory userData
    ) internal view override returns (uint256, uint256[] memory) {
        // If swaps are disabled, only proportional joins are allowed. All others involve implicit swaps,
        // and alter token prices.
        _require(
            getSwapEnabled() || userData.joinKind() == WeightedPoolUserData.JoinKind.ALL_TOKENS_IN_FOR_EXACT_BPT_OUT,
            Errors.INVALID_JOIN_EXIT_KIND_WHILE_SWAPS_DISABLED
        );
        // Check allowlist for LPs, if applicable
        _require(isAllowedAddress(sender), Errors.ADDRESS_NOT_ALLOWLISTED);

        return super._doJoin(sender, balances, normalizedWeights, scalingFactors, userData);
    }

    function _doExit(
        address sender,
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory scalingFactors,
        bytes memory userData
    ) internal view override returns (uint256, uint256[] memory) {
        // If swaps are disabled, only proportional exits are allowed. All others involve implicit swaps,
        // and alter token prices.
        WeightedPoolUserData.ExitKind kind = userData.exitKind();
        _require(
            getSwapEnabled() ||
                kind == WeightedPoolUserData.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT ||
                kind == WeightedPoolUserData.ExitKind.REMOVE_TOKEN,
            Errors.INVALID_JOIN_EXIT_KIND_WHILE_SWAPS_DISABLED
        );

        return
            kind == WeightedPoolUserData.ExitKind.REMOVE_TOKEN
                ? _doExitRemoveToken(sender, balances, userData)
                : super._doExit(sender, balances, normalizedWeights, scalingFactors, userData);
    }

    function _doExitRemoveToken(
        address sender,
        uint256[] memory balances,
        bytes memory userData
    ) private view whenNotPaused returns (uint256, uint256[] memory) {
        // This exit function is disabled if the contract is paused.

        // This exit function can only be called by the Pool itself - the authorization logic that governs when that
        // call can be made resides in removeToken.
        _require(sender == address(this), Errors.UNAUTHORIZED_EXIT);

        uint256 tokenIndex = userData.removeToken();

        // No BPT is required to remove the token - it is up to the caller to determine under which conditions removing
        // a token makes sense, and if e.g. burning BPT is required.
        uint256 bptAmountIn = 0;

        uint256[] memory amountsOut = new uint256[](balances.length);
        amountsOut[tokenIndex] = balances[tokenIndex];

        return (bptAmountIn, amountsOut);
    }

    function _tokenAddressToIndex(IERC20[] memory tokens, IERC20 token) internal pure returns (uint256) {
        uint256 tokensLength = tokens.length;
        for (uint256 i = 0; i < tokensLength; i++) {
            if (tokens[i] == token) {
                return i;
            }
        }

        _revert(Errors.INVALID_TOKEN);
    }

    /**
     * @dev When calling updateWeightsGradually again during an update, reset the start weights to the current weights,
     * if necessary.
     */
    function _startGradualWeightChange(
        uint256 startTime,
        uint256 endTime,
        uint256[] memory startWeights,
        uint256[] memory endWeights,
        IERC20[] memory tokens
    ) internal virtual {
        uint256 normalizedSum;

        for (uint256 i = 0; i < endWeights.length; i++) {
            uint256 endWeight = endWeights[i];
            _require(endWeight >= WeightedMath._MIN_WEIGHT, Errors.MIN_WEIGHT);
            normalizedSum = normalizedSum.add(endWeight);

            IERC20 token = tokens[i];
            _tokenState[token] = _encodeTokenState(token, startWeights[i], endWeight);
        }

        // Ensure that the normalized weights sum to ONE
        _require(normalizedSum == FixedPoint.ONE, Errors.NORMALIZED_WEIGHT_INVARIANT);

        _setMiscData(
            _getMiscData().insertUint32(startTime, _WEIGHT_START_TIME_OFFSET).insertUint32(
                endTime,
                _WEIGHT_END_TIME_OFFSET
            )
        );

        emit GradualWeightUpdateScheduled(startTime, endTime, startWeights, endWeights);
    }

    function _startGradualSwapFeeChange(
        uint256 startTime,
        uint256 endTime,
        uint256 startSwapFeePercentage,
        uint256 endSwapFeePercentage
    ) internal virtual {
        if (startSwapFeePercentage != getSwapFeePercentage()) {
            super._setSwapFeePercentage(startSwapFeePercentage);
        }

        _setSwapFeeData(startTime, endTime, endSwapFeePercentage);

        emit GradualSwapFeeUpdateScheduled(startTime, endTime, startSwapFeePercentage, endSwapFeePercentage);
    }

    function _setSwapFeeData(
        uint256 startTime,
        uint256 endTime,
        uint256 endSwapFeePercentage
    ) private {
        _setMiscData(
            _getMiscData()
                .insertUint31(startTime, _FEE_START_TIME_OFFSET)
                .insertUint31(endTime, _FEE_END_TIME_OFFSET)
                .insertUint64(endSwapFeePercentage, _END_SWAP_FEE_PERCENTAGE_OFFSET)
        );
    }

    // Factored out to avoid stack issues
    function _encodeTokenState(
        IERC20 token,
        uint256 startWeight,
        uint256 endWeight
    ) private view returns (bytes32) {
        bytes32 tokenState;

        // Tokens with more than 18 decimals are not supported
        // Scaling calculations must be exact/lossless
        // Store decimal difference instead of actual scaling factor
        return
            tokenState
                .insertUint64(
                _denormalizeWeight(startWeight).compress64(_MAX_DENORM_WEIGHT),
                _START_DENORM_WEIGHT_OFFSET
            )
                .insertUint64(_denormalizeWeight(endWeight).compress64(_MAX_DENORM_WEIGHT), _END_DENORM_WEIGHT_OFFSET)
                .insertUint5(uint256(18).sub(ERC20(address(token)).decimals()), _DECIMAL_DIFF_OFFSET);
    }

    // Convert a decimal difference value to the scaling factor
    function _readScalingFactor(bytes32 tokenState) private pure returns (uint256) {
        uint256 decimalsDifference = tokenState.decodeUint5(_DECIMAL_DIFF_OFFSET);

        return FixedPoint.ONE * 10**decimalsDifference;
    }

    /**
     * @dev Extend ownerOnly functions to include the Managed Pool control functions.
     */
    function _isOwnerOnlyAction(bytes32 actionId) internal view override returns (bool) {
        return
            (actionId == getActionId(ManagedPool.updateWeightsGradually.selector)) ||
            (actionId == getActionId(ManagedPool.updateSwapFeeGradually.selector)) ||
            (actionId == getActionId(ManagedPool.setSwapEnabled.selector)) ||
            (actionId == getActionId(ManagedPool.addAllowedAddress.selector)) ||
            (actionId == getActionId(ManagedPool.removeAllowedAddress.selector)) ||
            (actionId == getActionId(ManagedPool.setMustAllowlistLPs.selector)) ||
            (actionId == getActionId(ManagedPool.removeToken.selector)) ||
            (actionId == getActionId(ManagedPool.setManagementSwapFeePercentage.selector)) ||
            (actionId == getActionId(ManagedPool.setManagementAumFeePercentage.selector)) ||
            super._isOwnerOnlyAction(actionId);
    }

    function _getMaxSwapFeePercentage() internal pure virtual override returns (uint256) {
        return _MAX_MANAGEMENT_SWAP_FEE_PERCENTAGE;
    }

    function _getTokenData(IERC20 token) private view returns (bytes32 tokenData) {
        tokenData = _tokenState[token];

        // A valid token can't be zero (must have non-zero weights)
        _require(tokenData != 0, Errors.INVALID_TOKEN);
    }

    // Join/exit callbacks

    function _beforeJoinExit(
        uint256[] memory,
        uint256[] memory,
        uint256
    ) internal virtual override {
        // The AUM fee calculation is based on inflating the Pool's BPT supply by a target rate.
        // We then must collect AUM fees whenever joining or exiting the pool to ensure that LPs only pay AUM fees
        // for the period in which they are an LP within the pool, otherwise an LP could shift their share of AUM fees
        // onto the remaining LPs in the pool by exiting before it was paid.
        _collectAumManagementFees();
    }

    /**
     * @dev Calculates the AUM fees accrued since the last collection and pays it to the pool manager.
     * This function is called automatically on joins and exits.
     */
    function _collectAumManagementFees() internal returns (uint256 bptAmount) {
        uint256 lastCollection = _lastAumFeeCollectionTimestamp;
        uint256 currentTime = block.timestamp;

        // Collect fees based on the time elapsed
        if (currentTime > lastCollection) {
            // Reset the collection timer to the current block
            _lastAumFeeCollectionTimestamp = currentTime;

            uint256 managementAumFeePercentage = getManagementAumFeePercentage();

            // If `lastCollection` has not been set then we don't know what period over which to collect fees.
            // We then perform an early return after initializing it so that we can collect fees next time. This
            // means that AUM fees are not collected for any tokens the Pool is initialized with until the first
            // non-initialization join or exit.
            // We also perform an early return if the AUM fee is zero, to save gas.
            //
            // If the Pool has been paused, all fee calculation and minting is skipped to reduce execution
            // complexity to a minimum (and therefore likelihood of errors). We do still update the last
            // collection timestamp however, to avoid potentially collecting extra fees if the Pool were to
            // be later unpaused. Any fees that would be collected while the Pool is paused are lost.
            if (managementAumFeePercentage == 0 || lastCollection == 0 || !_isNotPaused()) {
                return 0;
            }

            // We want to collect fees so that the manager will receive `f` percent of the Pool's AUM after a year.
            // We compute the amount of BPT to mint for the manager that would allow it to proportionally exit the Pool
            // and receive this fraction of the Pool's assets.
            // Note that the total BPT supply will increase when minting, so we need to account for this
            // in order to compute the percentage of Pool ownership the manager will have.

            // The formula can be derived from:
            //
            // f = toMint / (supply + toMint)
            //
            // which can be rearranged into:
            //
            // toMint = supply * f / (1 - f)
            uint256 annualizedFee = totalSupply().mulDown(managementAumFeePercentage).divDown(
                managementAumFeePercentage.complement()
            );

            // This value is annualized, in reality we will be collecting fees regularly over the course of the year.
            // We then multiply this value by the fraction of the year which has elapsed since we last collected fees.
            uint256 elapsedTime = currentTime - lastCollection;
            uint256 fractionalTimePeriod = elapsedTime.divDown(365 days);
            bptAmount = annualizedFee.mulDown(fractionalTimePeriod);

            emit ManagementAumFeeCollected(bptAmount);

            _mintPoolTokens(getOwner(), bptAmount);
        }
    }

    // Functions that convert weights between internal (denormalized) and external (normalized) representations

    // Convert from the internal representation to normalized weights (summing to ONE)
    function _normalizeWeight(uint256 denormWeight) private view returns (uint256) {
        return denormWeight.divDown(_denormWeightSum);
    }

    // converts from normalized form to the internal representation (summing to _denormWeightSum)
    function _denormalizeWeight(uint256 weight) private view returns (uint256) {
        return weight.mulUp(_denormWeightSum);
    }
}
