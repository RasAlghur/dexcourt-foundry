// src/Voting.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Voting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error DisputeAlreadyRaised();
    error InvalidDispute();
    error NotYetOnDispute();
    error NotActive();
    error InvalidAmount();
    error UnAuthorized();
    error VoteStarted();
    error NotResolver();
    error ZeroAddress();

    // ===================================================== //
    // ====================== STRUCTS ====================== //
    // ===================================================== //

    struct Dispute {
        uint256 id;
        bool disputed;
        uint256 createdAt;
        uint256 disputeEndAt;
        address plaintiff;
        uint256 settledAt;
        bool finalized;
    }

    struct VotingConfig {
        uint256 disputeDuration;
        address vToken; //voteToken
        address feeRec; //feeRecipient
        address disputeResolver;
        uint256 feeAmount;
    }

    uint256 totalDisputes;

    // ===================================================== //
    // ====================== STORAGE ====================== //
    // ===================================================== //

    // Mappings (separate storage areas)
    mapping(uint256 => Dispute) private disputes;
    mapping(address => uint256) private pendingPayOut;

    // Packed storage structs
    VotingConfig _config;
    Dispute _disputes;

    enum DisputeOutcome {
        Resolved, // court ruled — split funds per verdict
        Dismissed, // case dismissed — split funds (e.g. refund or reward)
        Dropped // case dropped/withdrawn — no ruling, agreement resumes
    }

    // Events
    event DisputeRaised(
        uint256 votingId,
        address indexed plaintiff,
        bool probono,
        uint256 feeAmount,
        uint256 createdAt,
        uint256 disputeEndAt
    );
    event DisputeSettled(
        uint256 votingId,
        address indexed plaintiff,
        uint256 settledAt
    );
    event VotingConfigUpdated(
        uint256 disputeDuration,
        address voteToken,
        address feeRecipient,
        address disputeResolver,
        uint256 feeAmount
    );
    event PendingWithdrawn(address indexed recipient, uint256 amount);

    event DisputeFinalized(
        uint256 votingId,
        DisputeOutcome indexed outcome,
        address plaintiff
    );

    modifier onlyResolver() {
        _onlyResolver();
        _;
    }

    // ===================================================== //
    // ===================== INITIALIZE ==================== //
    // ===================================================== //

    constructor(
        address initialOwner,
        address _feeRecipient,
        address _voteToken,
        address _disputeResolver
    ) Ownable(initialOwner) {
        // Initialize config with default values
        _config = VotingConfig({
            disputeDuration: 24 hours,
            vToken: _voteToken,
            feeRec: _feeRecipient,
            disputeResolver: _disputeResolver,
            feeAmount: 0.01 ether
        });
    }

    // ===================================================== //
    // ===================== CORE LOGIC ==================== //
    // ===================================================== //

    function raiseDispute(
        uint256 votingId,
        bool proBono
    ) external payable nonReentrant returns (uint256) {
        Dispute storage d = disputes[votingId];
        if (d.disputed) revert DisputeAlreadyRaised(); // already exists

        if (d.id == 0) {
            d.id = votingId;
        }
        d.disputed = true;
        d.finalized = false;
        d.disputeEndAt = block.timestamp + _config.disputeDuration;
        if (d.createdAt == 0) {
            d.createdAt = block.timestamp;
        }
        if (d.settledAt != 0) {
            d.settledAt == 0;
        }
        d.plaintiff = msg.sender;
        totalDisputes++;

        if (!proBono) {
            if (_config.feeAmount == 0) revert InvalidAmount();
            // caller should send ETH with the call
            if (msg.value != _config.feeAmount) revert InvalidAmount();
            (bool sent, ) = payable(_config.feeRec).call{
                value: _config.feeAmount
            }("");
            if (!sent) {
                pendingPayOut[_config.feeRec] += _config.feeAmount;
            }
        }

        emit DisputeRaised(
            votingId,
            d.plaintiff,
            proBono,
            _config.feeAmount,
            d.createdAt,
            d.disputeEndAt
        );
        return votingId;
    }

    function settleDispute(
        uint256 votingId
    ) external payable nonReentrant returns (uint256) {
        Dispute storage d = disputes[votingId];
        if (d.createdAt == 0) revert InvalidDispute(); // already exists
        if (d.plaintiff != msg.sender) revert UnAuthorized();
        if (block.timestamp > d.disputeEndAt) revert VoteStarted(); // cannot settle if vote already enabled

        address _plaintiff = d.plaintiff;

        d.disputed = false;
        d.disputeEndAt = block.timestamp;
        d.settledAt = block.timestamp;
        d.finalized = true;
        d.plaintiff = address(0);
        emit DisputeSettled(votingId, _plaintiff, d.settledAt);
        return votingId;
    }

    // ===================================================== //
    // ==================== ADMIN SETTERS ================== //
    // ===================================================== //

    function setVotingConfig(
        uint256 _disputeDuration,
        address _vToken,
        address _feeRec,
        address _disputeResvr,
        uint256 _feeAmount
    ) external onlyOwner {
        _config.disputeDuration = _disputeDuration;
        _config.vToken = _vToken;
        _config.feeRec = _feeRec;
        _config.disputeResolver = _disputeResvr;
        _config.feeAmount = _feeAmount;
        emit VotingConfigUpdated(
            _disputeDuration,
            _vToken,
            _feeRec,
            _disputeResvr,
            _feeAmount
        );
    }

    /**
     * @notice Finalize a dispute after off-chain court/voting concludes.
     *
     * @param votingId            Off-chain vote id
     * @param outcome             Resolved | Dismissed | Dropped
     */
    function finalizeDispute(
        uint256 votingId,
        DisputeOutcome outcome
    ) external nonReentrant onlyResolver {
        Dispute storage d = disputes[votingId];
        if (!d.disputed) revert NotYetOnDispute();

        address _plaintiff = d.plaintiff;

        d.disputed = false;
        d.disputeEndAt = block.timestamp;
        d.plaintiff = address(0);

        emit DisputeFinalized(votingId, outcome, _plaintiff);
    }

    function _onlyResolver() internal view {
        if (msg.sender != _config.disputeResolver && msg.sender != owner())
            revert NotResolver();
    }

    // ===================================================== //
    // ===================== ANALYTICS ===================== //
    // ===================================================== //

    function getVotingConfig() public view returns (VotingConfig memory) {
        return _config;
    }

    // Recover stuck ETH or tokens
    function recoverStuckEth(uint256 _amount) external onlyOwner {
        uint256 bal = address(this).balance;

        if (bal >= _amount) {
            (bool okFee, ) = payable(owner()).call{value: _amount}("");
            if (!okFee) {
                revert();
            }
        }
    }

    function recoverStuckToken(
        address token,
        uint256 _amount
    ) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal >= _amount) IERC20(token).safeTransfer(owner(), _amount);
    }

    function getDisputeStats(
        uint256 _id
    )
        public
        view
        returns (
            uint256 id,
            uint256 createdAt,
            uint256 disputeEndAt,
            address plaintiff,
            uint256 settledAt,
            bool finalized
        )
    {
        Dispute storage d = disputes[_id];
        if (d.createdAt == 0) revert InvalidDispute();

        return (
            d.id,
            d.createdAt,
            d.disputeEndAt,
            d.plaintiff,
            d.settledAt,
            d.finalized
        );
    }

    function getStats() public view returns (uint256 totalDisputes_) {
        totalDisputes_ = totalDisputes;
    }
}
