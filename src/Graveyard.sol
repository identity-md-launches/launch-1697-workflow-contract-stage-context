// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Bury an entire balance of an approved token and receive a declining WAKE reward.
/// @dev No withdrawal, upgrade, ownership transfer, receive or fallback function exists.
contract Graveyard is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant REWARD_DIVISOR = 2_000;
    uint256 public constant MAX_BURY_BATCH = 50;
    uint256 public constant MAX_PAGE_SIZE = 100;
    uint256 public constant MAX_EPITAPH_BYTES = 64;

    address public immutable owner;
    IERC20 public wakeToken;

    struct Tombstone {
        address token;
        address firstMourner;
        uint256 firstBurialTime;
        uint256 mourners;
        uint256 totalBuried;
        string epitaphText;
        bool epitaphWritten;
        uint256 flowers;
    }

    struct WalletRecord {
        uint256 burials;
        uint256 wakeEarned;
    }

    address[] private _consecratedTokens;
    mapping(address token => bool) public consecrated;
    mapping(address token => Tombstone) private _tombstones;
    mapping(address wallet => mapping(address token => bool)) public hasBuried;
    mapping(address wallet => WalletRecord) public walletRecords;

    uint256 public totalBurials;
    uint256 public totalTokensBuried;
    uint256 public totalMourners;
    uint256 public totalWakePaidOut;
    uint256 public totalFlowersBurned;

    error Unauthorized();
    error InvalidAddress();
    error WakeNotConfigured();
    error WakeAlreadyConfigured();
    error InvalidToken(address token);
    error WakeCannotBeBuried();
    error AlreadyConsecrated(address token);
    error NotConsecrated(address token);
    error AlreadyBuried(address wallet, address token);
    error EmptyBalance(address token);
    error InvalidBatchSize(uint256 size);
    error PageTooLarge(uint256 count);
    error NoTombstone(address token);
    error NotFirstMourner();
    error EpitaphAlreadyWritten();
    error EpitaphTooLong(uint256 length);
    error ZeroAmount();
    error InexactTransfer(address token);

    event WakeTokenSet(address indexed token);
    event Consecrated(address indexed token);
    event Funded(address indexed funder, uint256 amount);
    event Buried(address indexed token, address indexed mourner, uint256 amount, uint256 reward);
    event Epitaph(address indexed token, address indexed mourner, string text);
    event Flowers(address indexed token, address indexed mourner, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @param initialOwner The launch owner ($owner), never the deploying factory.
    /// @dev No external calls or code requirements: safe to deploy on an empty chain.
    constructor(address initialOwner) {
        if (initialOwner == address(0) || initialOwner == DEAD) revert InvalidAddress();
        owner = initialOwner;
    }

    /// @notice Permanently bind this cemetery to the deployed LaunchToken.
    /// @dev The owner must verify the address against the deployment handoff before calling.
    function setWakeToken(address token) external nonReentrant onlyOwner {
        if (address(wakeToken) != address(0)) revert WakeAlreadyConfigured();
        _validateToken(token);
        wakeToken = IERC20(token);
        emit WakeTokenSet(token);
    }

    /// @notice Append tokens in order. Duplicates and invalid entries revert the whole call.
    function consecrate(address[] calldata tokens) external nonReentrant onlyOwner {
        _requireWake();
        if (tokens.length == 0) revert InvalidBatchSize(0);
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (token == address(wakeToken)) revert WakeCannotBeBuried();
            _validateToken(token);
            if (consecrated[token]) revert AlreadyConsecrated(token);
            consecrated[token] = true;
            _consecratedTokens.push(token);
            _tombstones[token].token = token;
            emit Consecrated(token);
        }
    }

    /// @notice Deposit approved WAKE from the owner; deposits are irrevocable.
    function fund(uint256 amount) external nonReentrant onlyOwner {
        IERC20 wake = _requireWake();
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = wake.balanceOf(address(this));
        wake.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = wake.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert InexactTransfer(address(wake));
        }
        emit Funded(msg.sender, amount);
    }

    /// @notice Send the caller's complete token balance to DEAD and pay the current reward.
    function bury(address token) external nonReentrant returns (uint256 reward) {
        _requireWake();
        reward = _bury(token, msg.sender);
    }

    /// @notice Atomically bury 1..50 tokens in order; each reward uses the remaining vault balance.
    function buryMany(address[] calldata tokens) external nonReentrant returns (uint256 totalReward) {
        _requireWake();
        if (tokens.length == 0 || tokens.length > MAX_BURY_BATCH) revert InvalidBatchSize(tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            totalReward += _bury(tokens[i], msg.sender);
        }
    }

    /// @notice The first mourner may write up to 64 bytes, once. Empty text also consumes the right.
    function epitaph(address token, string calldata text) external nonReentrant {
        Tombstone storage tombstone = _tombstones[token];
        if (tombstone.mourners == 0) revert NoTombstone(token);
        if (tombstone.firstMourner != msg.sender) revert NotFirstMourner();
        if (tombstone.epitaphWritten) revert EpitaphAlreadyWritten();
        if (bytes(text).length > MAX_EPITAPH_BYTES) revert EpitaphTooLong(bytes(text).length);
        tombstone.epitaphWritten = true;
        tombstone.epitaphText = text;
        emit Epitaph(token, msg.sender, text);
    }

    /// @notice Burn the caller's approved WAKE on a token with at least one burial.
    /// @dev Flowers never spend the reward vault and never earn a reward.
    function layFlowers(address token, uint256 amount) external nonReentrant {
        IERC20 wake = _requireWake();
        if (_tombstones[token].mourners == 0) revert NoTombstone(token);
        if (amount == 0) revert ZeroAmount();
        _tombstones[token].flowers += amount;
        totalFlowersBurned += amount;
        _transferToDead(wake, msg.sender, amount);
        emit Flowers(token, msg.sender, amount);
    }

    /// @notice Includes consecrated tokens awaiting a first burial, in consecration order.
    /// @dev start beyond the end or count == 0 returns an empty page; count > 100 reverts.
    function getTombstones(uint256 start, uint256 count) external view returns (Tombstone[] memory page) {
        if (count > MAX_PAGE_SIZE) revert PageTooLarge(count);
        uint256 length = _consecratedTokens.length;
        if (start >= length) return new Tombstone[](0);
        uint256 remaining = length - start;
        if (count > remaining) count = remaining;
        page = new Tombstone[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _tombstones[_consecratedTokens[start + i]];
        }
    }

    function getTombstone(address token) external view returns (Tombstone memory) {
        return _tombstones[token];
    }

    function consecratedCount() external view returns (uint256) {
        return _consecratedTokens.length;
    }

    /// @notice Eligibility hint, not a guarantee of allowance, transferability, or inclusion order.
    /// @dev A reverting or malformed balanceOf returns false rather than breaking wallet discovery.
    function canBury(address wallet, address token) external view returns (bool) {
        if (
            address(wakeToken) == address(0) || wallet == address(0) || wallet == DEAD || !consecrated[token]
                || hasBuried[wallet][token] || token.code.length == 0
        ) return false;
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (wallet)));
        return success && data.length == 32 && abi.decode(data, (uint256)) > 0;
    }

    /// @notice floor(vault WAKE / 2000), in WAKE minor units. Reverts until WAKE is configured.
    function nextReward() public view returns (uint256) {
        return _requireWake().balanceOf(address(this)) / REWARD_DIVISOR;
    }

    function _bury(address token, address mourner) private returns (uint256 reward) {
        if (!consecrated[token]) revert NotConsecrated(token);
        if (hasBuried[mourner][token]) revert AlreadyBuried(mourner, token);
        IERC20 buriedToken = IERC20(token);
        uint256 amount = buriedToken.balanceOf(mourner);
        if (amount == 0) revert EmptyBalance(token);
        // Sample before calling the burial token; later donations affect subsequent burials.
        reward = nextReward();

        hasBuried[mourner][token] = true;
        Tombstone storage tombstone = _tombstones[token];
        if (tombstone.mourners == 0) {
            tombstone.firstMourner = mourner;
            tombstone.firstBurialTime = block.timestamp;
            ++totalTokensBuried;
        }
        ++tombstone.mourners;
        tombstone.totalBuried += amount;

        WalletRecord storage wallet = walletRecords[mourner];
        if (wallet.burials == 0) ++totalMourners;
        ++wallet.burials;
        wallet.wakeEarned += reward;
        ++totalBurials;
        totalWakePaidOut += reward;

        _transferToDead(buriedToken, mourner, amount);
        if (reward != 0) wakeToken.safeTransfer(mourner, reward);
        emit Buried(token, mourner, amount, reward);
    }

    /// @dev Reject taxed, rebasing-during-transfer and no-op tokens to preserve exact burn records.
    function _transferToDead(IERC20 token, address from, uint256 amount) private {
        uint256 senderBefore = token.balanceOf(from);
        uint256 deadBefore = token.balanceOf(DEAD);
        token.safeTransferFrom(from, DEAD, amount);
        uint256 senderAfter = token.balanceOf(from);
        uint256 deadAfter = token.balanceOf(DEAD);
        if (
            senderBefore < amount || senderAfter != senderBefore - amount || deadAfter < deadBefore
                || deadAfter - deadBefore != amount
        ) revert InexactTransfer(address(token));
    }

    function _requireWake() private view returns (IERC20 wake) {
        wake = wakeToken;
        if (address(wake) == address(0)) revert WakeNotConfigured();
    }

    function _validateToken(address token) private view {
        if (token == address(this) || token == DEAD || token.code.length == 0) revert InvalidToken(token);
    }
}
