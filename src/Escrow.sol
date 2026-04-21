// src/AgreementEscrow.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AgreementEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotParty();
    error NotActive();
    error InvalidAmount();
    error CannotBeTheSame();
    error ZeroAddress();
    error NotYetFunded();
    error AlreadySigned();
    error AlreadyAccepted();
    error AlreadyFunded();
    error Grace1NotEnded();
    error Grace2NotEnded();
    error Grace1PeriodEnded();
    error AlreadyInGracePeriod();
    error NoActionMade();
    error NotSigned();
    error InitiatorCannotRespond();
    error AlreadyPendingCancellation();
    error InVestingStage();
    error NoVestingStage();
    error MilestoneHeld();
    error MilestoneAlreadyClaimed();
    error InvalidMilestoneConfig();
    error MilestoneNotUnlocked();
    error OffsetExceedsDeadline();
    error NotYetOnDispute();
    error VoteStarted();
    error DisputeRaisedAlready();
    error InvalidAgreement();
    error NotFrozen();
    error NotResolver();

    // ===================================================== //
    // ===================== STRUCTS ======================= //
    // ===================================================== //

    struct Agreement {
        uint256 id;
        address payable creator; // who created the record
        address payable serviceProvider; // the other party
        address payable serviceRecipient; // the other party
        address token; // 0x0 = ETH, else ERC20
        uint256 amount; // original locked amount
        uint256 remainingAmount; // remaining locked amount available to release
        uint256 createdAt;
        uint256 deadline; // absolute timestamp (set when fully signed)
        uint256 deadlineDuration; // duration in seconds (set at creation)
        uint256 grace1Ends;
        uint256 grace2Ends;
        address grace1EndsCalledBy;
        address grace2EndsCalledBy;
        bool funded;
        bool signed; // true when both parties accepted
        bool acceptedByServiceProvider; // serviceProvider accepted terms
        bool acceptedByServiceRecipient; // serviceRecipient accepted terms
        bool completed;
        bool disputed;
        bool privateMode;
        bool frozen;
        bool pendingCancellation;
        bool orderCancelled;
        bool vesting;
        bool deliverySubmited;
        uint256 votingId;
        uint256 disputeEndAt;
        address plaintiff;
        address defendant;
    }

    struct Milestone {
        uint256 percentBp; // basis points from 0..10000
        uint256 unlockAt; // absolute timestamp when claimable (set at signing)
        bool heldByRecipient; // if true, serviceRecipient put this milestone on hold (cannot be claimed)
        bool claimed; // whether this milestone has been claimed
    }

    struct EscrowConfigs {
        uint256 platformFeeBp;
        uint256 feeAmount;
        uint256 disputeDuration;
        uint256 grace1Duration;
        uint256 grace2Duration;
    }

    enum DisputeOutcome {
        Resolved, // court ruled — split funds per verdict
        Dismissed, // case dismissed — split funds (e.g. refund or reward)
        Dropped // case dropped/withdrawn — no ruling, agreement resumes
    }

    // ===================================================== //
    // ===================== STORAGE ======================= //
    // ===================================================== //

    uint256 totalAgreements;
    uint256 totalDisputes;
    uint256 totalSmooth;
    uint256 totalFeesTaken;
    uint256 totalEscrowedEth;
    mapping(uint256 => Agreement) private agreements;
    mapping(address => uint256) private pendingPayOut;

    mapping(uint256 => uint256[]) private _milestonePercBp;
    mapping(uint256 => uint256[]) private _milestoneOffsets;
    mapping(uint256 => Milestone[]) private _milestones;

    // configuration
    EscrowConfigs _config;
    address feeRecipient;
    address disputeResolver;

    uint256 constant DIV = 10000;

    // ===================================================== //
    // ====================== EVENTS ======================= //
    // ===================================================== //

    event AgreementCreated(
        uint256 indexed id,
        address creator,
        address indexed serviceProvider,
        address indexed serviceRecipient,
        address token,
        uint256 amount,
        bool vestingMode,
        bool privateMode
    );
    event AgreementSigned(
        uint256 indexed id,
        address indexed serviceProvider,
        address indexed serviceRecipient
    );
    event FundsDeposited(
        uint256 indexed id,
        address by,
        address token,
        uint256 amount
    );
    event DeliverySubmitted(uint256 indexed id, address by);
    event DeliveryApproved(uint256 indexed id, address by);
    event DeliveryRejected(uint256 indexed id, address by);
    event OrderCancelled(uint256 indexed id, address by);
    event CancellationRejected(uint256 indexed id, address by);
    event CancellationApproved(uint256 indexed id, address by);
    event FundsReleased(
        uint256 indexed id,
        uint256 toServiceProvider,
        uint256 toServiceRecipient,
        uint256 fee
    );
    event DisputeRaised(
        uint256 indexed id,
        bool probono,
        uint256 feeAmount,
        address plaintiff,
        address defendant,
        uint256 votingId
    );
    event DisputeSettled(
        uint256 indexed id,
        address plaintiff,
        address defendant,
        uint256 votingId
    );
    event PlatformFeeUpdated(uint256 feeBp);
    event GracePeriodUpdated(uint256 grace1, uint256 grace2);
    event StuckFundsRecovered(address token, uint256 amount);
    event AgreementCompleted(uint256 indexed id, bool disputed);
    event AgreementFrozen(uint256 indexed id, bool status);
    event FeeRecipientUpdated(address recipient);

    event VestingConfigured(uint256 indexed id);
    event MilestoneClaimed(
        uint256 indexed id,
        address by,
        uint256 indexed idx,
        uint256 amount
    );
    event MilestoneHoldUpdated(
        uint256 indexed id,
        address by,
        uint256 indexed idx,
        bool heldByRecipient
    );
    event EscrowConfigUpdated(
        uint256 platformFeeBp,
        uint256 feeAmount,
        uint256 disputeDuration,
        uint256 grace1Duration,
        uint256 grace2Duration
    );
    event DisputeFinalized(
        uint256 indexed id,
        DisputeOutcome indexed outcome,
        address plaintiff,
        address defendant,
        uint256 toServiceProvider,
        uint256 toServiceRecipient,
        uint256 votingId
    );

    // ===================================================== //
    // ===================== MODIFIERS ===================== //
    // ===================================================== //

    modifier onlyParties(uint256 id) {
        _onlyParties(id);
        _;
    }

    modifier onlyActive(uint256 id) {
        _onlyActive(id);
        _;
    }

    modifier onlyResolver() {
        _onlyResolver();
        _;
    }

    constructor(
        address initialOwner,
        address _feeRec,
        address _disputeResolver
    ) Ownable(initialOwner) {
        feeRecipient = _feeRec;
        disputeResolver = _disputeResolver;

        _config = EscrowConfigs({
            platformFeeBp: 300,
            feeAmount: 0.01 ether,
            disputeDuration: 24 hours,
            grace1Duration: 24 hours,
            grace2Duration: 24 hours
        });
    }

    // ===================================================== //
    // ================== CONFIG FUNCTIONS ================= //
    // ===================================================== //

    function getEscrowConfigs() public view returns (EscrowConfigs memory) {
        return _config;
    }

    function setEscrowConfig(
        uint256 _platformFeeBp,
        uint256 _feeAmount,
        uint256 _disputeDuration,
        uint256 _grace1Duration,
        uint256 _grace2Duration
    ) external onlyOwner {
        _config.platformFeeBp = _platformFeeBp;
        _config.feeAmount = _feeAmount;
        _config.disputeDuration = _disputeDuration;
        _config.grace1Duration = _grace1Duration;
        _config.grace2Duration = _grace2Duration;

        emit EscrowConfigUpdated(
            _platformFeeBp,
            _feeAmount,
            _disputeDuration,
            _grace1Duration,
            _grace2Duration
        );
    }

    function setDisputeResolver(address _resolver) external onlyOwner {
        if (_resolver == address(0)) revert ZeroAddress();
        disputeResolver = _resolver;
    }

    // ===================================================== //
    // ================== CORE AGREEMENT =================== //
    // ===================================================== //

    /**
     * @notice Create an agreement. Optionally fund it immediately.
     * @param _agreementId agreementId
     * @param _serviceProvider serviceProvider
     * @param _serviceRecipient serviceRecipient
     * @param _token token address (address(0) = ETH)
     * @param _amount agreed amount (wei or token smallest unit)
     * @param _deadlineDuration seconds (duration after signing for the deadline)
     * @param _privateMode visibility
     * @param milestonePercs basis points per milestone (array). Required if vestingMode true.
     * @param milestoneOffsets seconds-from-signing for each milestone (array). Required if vestingMode true.
     */

    function createAgreement(
        uint256 _agreementId,
        address payable _serviceProvider,
        address payable _serviceRecipient,
        address _token,
        uint256 _amount,
        uint256 _deadlineDuration,
        bool vestingMode,
        bool _privateMode,
        uint256[] memory milestonePercs,
        uint256[] memory milestoneOffsets
    ) external payable nonReentrant returns (uint256) {
        Agreement storage a = agreements[_agreementId];
        if (a.createdAt != 0) revert InvalidAgreement(); // already exists
        if (_amount <= 0) revert InvalidAmount();
        if (_serviceRecipient == _serviceProvider) revert CannotBeTheSame();
        if (_serviceRecipient == address(0) || _serviceProvider == address(0))
            revert ZeroAddress();

        a.id = _agreementId;
        a.creator = payable(msg.sender);
        a.serviceProvider = _serviceProvider;
        a.serviceRecipient = _serviceRecipient;
        a.token = _token;
        a.amount = _amount;
        a.createdAt = block.timestamp;
        a.deadlineDuration = _deadlineDuration;
        a.privateMode = _privateMode;
        a.vesting = vestingMode;

        if (msg.sender == _serviceRecipient)
            a.acceptedByServiceRecipient = true;
        if (msg.sender == _serviceProvider) a.acceptedByServiceProvider = true;

        if (vestingMode) {
            if (
                milestonePercs.length == 0 ||
                milestonePercs.length != milestoneOffsets.length
            ) revert InvalidMilestoneConfig();

            if (_deadlineDuration == 0) revert InvalidMilestoneConfig();

            // copy to storage
            uint256 totalBp = 0;
            uint256 mLenght = milestonePercs.length;
            for (uint256 i = 0; i < mLenght; i++) {
                if (milestoneOffsets[i] > _deadlineDuration)
                    revert OffsetExceedsDeadline();

                _milestonePercBp[_agreementId].push(milestonePercs[i]);
                _milestoneOffsets[_agreementId].push(milestoneOffsets[i]);
                totalBp += milestonePercs[i];
            }
            if (totalBp != DIV) revert InvalidMilestoneConfig();
        }

        totalAgreements++;

        if (msg.sender == _serviceRecipient) {
            if (_token == address(0)) {
                if (msg.value != _amount) revert InvalidAmount();
                totalEscrowedEth += msg.value;
            } else {
                IERC20(_token).safeTransferFrom(
                    _serviceRecipient,
                    address(this),
                    _amount
                );
            }

            a.funded = true;
            a.remainingAmount = _amount;

            emit FundsDeposited(a.id, msg.sender, _token, _amount);
        }

        if (
            a.acceptedByServiceRecipient &&
            a.acceptedByServiceProvider &&
            !a.signed
        ) {
            a.signed = true;
            if (a.deadlineDuration > 0) {
                a.deadline = block.timestamp + _deadlineDuration;
            }
            if (a.vesting) {
                _configureMilestonesOnSign(_agreementId);
            }
            emit AgreementSigned(a.id, _serviceProvider, _serviceRecipient);
        }

        emit AgreementCreated(
            a.id,
            msg.sender,
            _serviceProvider,
            _serviceRecipient,
            _token,
            _amount,
            vestingMode,
            _privateMode
        );
        return a.id;
    }

    function signAgreement(uint256 id) external onlyParties(id) onlyActive(id) {
        Agreement storage a = agreements[id];
        if (!a.funded) revert NotYetFunded();
        if (a.signed) revert AlreadySigned();

        if (msg.sender == a.serviceProvider) {
            if (a.acceptedByServiceProvider) revert AlreadyAccepted();
            a.acceptedByServiceProvider = true;
            emit AgreementSigned(id, a.serviceProvider, a.serviceRecipient);
        } else {
            if (a.acceptedByServiceRecipient) revert AlreadyAccepted();
            a.acceptedByServiceRecipient = true;
            emit AgreementSigned(id, a.serviceProvider, a.serviceRecipient);
        }

        // If both accepted, finalize and start deadline
        if (
            a.acceptedByServiceRecipient &&
            a.acceptedByServiceProvider &&
            !a.signed
        ) {
            a.signed = true;
            if (a.deadlineDuration > 0)
                a.deadline = block.timestamp + a.deadlineDuration;

            if (a.vesting) {
                _configureMilestonesOnSign(id);
            }
            emit AgreementSigned(id, a.serviceProvider, a.serviceRecipient);
        }
    }

    function depositFunds(
        uint256 id
    ) external payable nonReentrant onlyActive(id) {
        Agreement storage a = agreements[id];
        if (a.funded) revert AlreadyFunded();
        if (msg.sender != a.serviceRecipient) revert NotParty(); // add this

        if (a.token == address(0)) {
            if (msg.value != a.amount) revert InvalidAmount();
            totalEscrowedEth += msg.value;
        } else {
            IERC20(a.token).safeTransferFrom(
                msg.sender,
                address(this),
                a.amount
            );
        }

        a.acceptedByServiceRecipient = true;

        if (
            a.acceptedByServiceRecipient &&
            a.acceptedByServiceProvider &&
            !a.signed
        ) {
            a.signed = true;
            if (a.deadlineDuration > 0)
                a.deadline = block.timestamp + a.deadlineDuration;

            if (a.vesting) {
                _configureMilestonesOnSign(id);
            }

            emit AgreementSigned(id, a.serviceProvider, a.serviceRecipient);
        }

        a.funded = true;
        a.remainingAmount = a.amount; // set remaining on first deposit
        emit FundsDeposited(id, msg.sender, a.token, a.amount);
    }

    function submitDelivery(uint256 id) external nonReentrant onlyActive(id) {
        Agreement storage a = agreements[id];
        if (msg.sender != a.serviceProvider) revert NotParty();
        if (!a.funded) revert NotYetFunded();
        if (!a.signed) revert NotSigned();
        if (a.pendingCancellation) revert AlreadyPendingCancellation();
        if (a.grace1Ends != 0) revert AlreadyInGracePeriod();

        // start grace1 countdown
        a.deliverySubmited = true;
        if (!a.vesting) {
            a.grace1Ends = block.timestamp + _config.grace1Duration;
            a.grace1EndsCalledBy = a.serviceProvider;
        }
        emit DeliverySubmitted(id, msg.sender);
    }

    function approveDelivery(
        uint256 id,
        bool _final,
        uint256 votingId,
        bool proBono
    ) external payable nonReentrant onlyActive(id) {
        Agreement storage a = agreements[id];
        if (msg.sender != a.serviceRecipient) revert NotParty();
        if (!a.funded) revert NotYetFunded();
        if (!a.signed) revert NotSigned();
        if (a.disputed) revert DisputeRaisedAlready();
        if (a.pendingCancellation) revert AlreadyPendingCancellation();
        if (a.grace1Ends == 0) revert NoActionMade();
        if (!_final && votingId == 0) revert InvalidAmount();

        if (_final) {
            _releaseFunds(a, 0, a.remainingAmount, true);
            emit DeliveryApproved(id, msg.sender);
        } else {
            a.deliverySubmited = false;
            a.grace1Ends = 0;
            a.grace1EndsCalledBy = address(0);

            if (!_final) {
                a.plaintiff = a.serviceRecipient;
                a.defendant = a.serviceProvider;
                a.disputed = true;

                a.disputeEndAt = block.timestamp + _config.disputeDuration;
                a.privateMode = false;
                a.frozen = true;
                totalDisputes++;

                if (!proBono) {
                    if (_config.feeAmount == 0) revert InvalidAmount();
                    // caller should send ETH with the call
                    if (msg.value != _config.feeAmount) revert InvalidAmount();
                    (bool sent, ) = payable(feeRecipient).call{
                        value: _config.feeAmount
                    }("");
                    if (!sent) {
                        pendingPayOut[feeRecipient] += _config.feeAmount;
                    }
                }

                emit DisputeRaised(
                    id,
                    proBono,
                    _config.feeAmount,
                    a.plaintiff,
                    a.defendant,
                    a.votingId
                );
            }

            emit DeliveryRejected(id, msg.sender);
        }
    }

    function cancelOrder(
        uint256 id
    ) external nonReentrant onlyActive(id) onlyParties(id) {
        Agreement storage a = agreements[id];
        if (!a.funded) revert NotYetFunded();
        if (!a.signed) revert NotSigned();
        if (a.pendingCancellation) revert AlreadyPendingCancellation();
        if (a.grace1Ends != 0) revert AlreadyInGracePeriod();

        a.grace1Ends = block.timestamp + _config.grace1Duration;
        if (msg.sender == a.serviceRecipient)
            a.grace1EndsCalledBy = a.serviceRecipient;
        a.pendingCancellation = true;
        if (msg.sender == a.serviceProvider)
            a.grace1EndsCalledBy = a.serviceProvider;
        a.pendingCancellation = true;

        emit OrderCancelled(id, msg.sender);
    }

    function approveCancellation(
        uint256 id,
        bool _final
    ) external nonReentrant onlyActive(id) onlyParties(id) {
        Agreement storage a = agreements[id];
        if (!a.funded) revert NotYetFunded();
        if (!a.signed) revert NotSigned();
        if (a.grace1Ends == 0) revert NoActionMade();
        if (!a.pendingCancellation) revert NoActionMade();

        if (block.timestamp > a.grace1Ends) revert Grace1PeriodEnded();

        if (msg.sender == a.grace1EndsCalledBy) revert InitiatorCannotRespond();

        if (_final) {
            a.orderCancelled = true;
            a.pendingCancellation = false;
            _releaseFunds(a, a.remainingAmount, 0, true);
            emit CancellationApproved(id, msg.sender);
        } else {
            a.grace1Ends = 0;
            a.pendingCancellation = false;
            a.grace1EndsCalledBy = address(0);
            emit CancellationRejected(id, msg.sender);
        }
    }

    /// @notice ServiceProvider can claim a single milestone if unlocked and not held
    function claimMilestone(
        uint256 id,
        uint256 idx
    ) external nonReentrant onlyActive(id) {
        Agreement storage a = agreements[id];
        if (!a.funded) revert NotYetFunded();
        if (!a.signed) revert NotSigned();
        if (!a.vesting) revert NoVestingStage();
        if (msg.sender != a.serviceProvider) revert NotParty();
        if (a.grace1Ends != 0 && block.timestamp < a.grace1Ends) {
            revert AlreadyInGracePeriod();
        }
        if (idx >= _milestones[id].length) revert InvalidAmount();
        Milestone storage m = _milestones[id][idx];
        if (m.claimed) revert MilestoneAlreadyClaimed();
        if (m.heldByRecipient) revert MilestoneHeld();
        if (block.timestamp < m.unlockAt) revert MilestoneNotUnlocked(); // reuse error name for "not yet unlocked"

        uint256 amountForMilestone = (a.amount * m.percentBp) / DIV;
        if (amountForMilestone == 0) revert InvalidAmount();

        m.claimed = true;

        // call internal release (to serviceProvider)
        _releaseFunds(a, 0, amountForMilestone, false);

        emit MilestoneClaimed(id, msg.sender, idx, amountForMilestone);
    }

    /// @notice ServiceRecipient may hold or release a milestone (preventing or allowing claims)
    function setMilestoneHold(
        uint256 id,
        uint256 idx,
        bool hold
    ) external nonReentrant onlyActive(id) {
        Agreement storage a = agreements[id];
        if (msg.sender != a.serviceRecipient) revert NotParty();
        if (!a.vesting) revert NoVestingStage();
        if (idx >= _milestones[id].length) revert InvalidAmount();

        Milestone storage m = _milestones[id][idx];
        if (m.claimed) revert MilestoneAlreadyClaimed();

        m.heldByRecipient = hold;
        emit MilestoneHoldUpdated(id, msg.sender, idx, hold);
    }

    // getter helpers for milestone info
    function getMilestoneCount(uint256 id) external view returns (uint256) {
        return _milestones[id].length;
    }

    function getMilestone(
        uint256 id,
        uint256 idx
    )
        external
        view
        returns (
            uint256 percentBp,
            uint256 unlockAt,
            bool heldByRecipient,
            bool claimed,
            uint256 amount
        )
    {
        Milestone storage m = _milestones[id][idx];
        Agreement storage a = agreements[id];
        percentBp = m.percentBp;
        unlockAt = m.unlockAt;
        heldByRecipient = m.heldByRecipient;
        claimed = m.claimed;
        amount = (a.amount * m.percentBp) / DIV;
    }

    // ===================================================== //
    // ================== GRACE PERIOD LOGIC =============== //
    // ===================================================== //

    /**
     * @notice After grace1 has expired, anyone interacting can finalize the cancellation.
     * @param id agreement id
     */
    function enforceCancellationTimeout(
        uint256 id
    ) public nonReentrant onlyActive(id) {
        Agreement storage a = agreements[id];
        if (a.grace1Ends == 0) revert NoActionMade();
        if (block.timestamp < a.grace1Ends) revert Grace1NotEnded();
        if (!a.funded) revert NotYetFunded();
        if (!a.pendingCancellation) revert NoActionMade();

        a.orderCancelled = true;
        a.pendingCancellation = false;
        _releaseFunds(a, a.remainingAmount, 0, true);

        emit CancellationApproved(id, msg.sender);
    }

    function partialAutoRelease(uint256 id) public nonReentrant onlyActive(id) {
        Agreement storage a = agreements[id];

        if (a.grace1Ends == 0) revert NoActionMade();
        if (a.vesting) revert InVestingStage();
        if (block.timestamp < a.grace1Ends) revert Grace1NotEnded();

        if (!a.funded) revert NotYetFunded();
        if (a.pendingCancellation) revert AlreadyPendingCancellation();

        uint256 half = a.remainingAmount / 2;
        if (half == 0) revert InvalidAmount();

        if (a.grace1EndsCalledBy == a.serviceRecipient) {
            _releaseFunds(a, half, 0, false);
        } else if (a.grace1EndsCalledBy == a.serviceProvider) {
            _releaseFunds(a, 0, half, false);
        }

        // start grace2 only if there is still remaining amount
        if (a.remainingAmount > 0) {
            a.grace2Ends = block.timestamp + _config.grace2Duration;
            if (a.grace1EndsCalledBy == a.serviceRecipient) {
                a.grace2EndsCalledBy = a.serviceRecipient;
            } else if (a.grace1EndsCalledBy == a.serviceProvider) {
                a.grace2EndsCalledBy = a.serviceProvider;
            }
        } else {
            // all funds exhausted, mark completed
            a.completed = true;
            a.frozen = false;
            totalSmooth++;
            emit AgreementCompleted(a.id, a.disputed);
        }
    }

    function finalAutoRelease(uint256 id) public nonReentrant onlyActive(id) {
        Agreement storage a = agreements[id];

        if (a.grace2Ends == 0) revert NoActionMade();
        if (a.vesting) revert InVestingStage();
        if (block.timestamp < a.grace2Ends) revert Grace2NotEnded();

        if (!a.funded) revert NotYetFunded();
        uint256 remaining = a.remainingAmount;
        if (remaining == 0) revert InvalidAmount();

        if (a.grace2EndsCalledBy == a.serviceRecipient) {
            _releaseFunds(a, remaining, 0, true);
        } else if (a.grace2EndsCalledBy == a.serviceProvider) {
            _releaseFunds(a, 0, remaining, true);
        }
    }

    // ===================================================== //
    // =================== DISPUTE LOGIC =================== //
    // ===================================================== //

    /**
     * @notice Raise a dispute for an agreement. Caller must be a party.
     * @dev This function currently supports ETH filing fee when called via escrow (msg.value).
     *
     * @param id agreement id
     * @param votingId voting id
     *
     * Requirements:
     *  - agreement must be funded
     *  - caller must be one of the parties
     */
    function raiseDispute(
        uint256 id,
        uint256 votingId,
        bool proBono
    ) external payable onlyActive(id) onlyParties(id) {
        Agreement storage a = agreements[id];
        if (!a.funded) revert NotYetFunded();
        if (!a.signed) revert NotSigned();
        if (a.disputed) revert DisputeRaisedAlready();
        if (a.pendingCancellation) revert AlreadyPendingCancellation();
        if (votingId == 0) revert InvalidAmount();

        if (msg.sender == a.serviceRecipient) {
            a.plaintiff = a.serviceRecipient;
            a.defendant = a.serviceProvider;
        } else if (msg.sender == a.serviceProvider) {
            a.plaintiff = a.serviceProvider;
            a.defendant = a.serviceRecipient;
        }

        a.disputed = true;
        a.disputeEndAt = block.timestamp + _config.disputeDuration;
        a.privateMode = false;
        a.frozen = true;
        totalDisputes++;

        if (a.votingId == 0) {
            a.votingId = votingId;
        }

        if (!proBono) {
            if (_config.feeAmount == 0) revert InvalidAmount();
            // caller should send ETH with the call
            if (msg.value != _config.feeAmount) revert InvalidAmount();
            (bool sent, ) = payable(feeRecipient).call{
                value: _config.feeAmount
            }("");
            if (!sent) {
                pendingPayOut[feeRecipient] += _config.feeAmount;
            }
        }

        emit DisputeRaised(
            id,
            proBono,
            _config.feeAmount,
            a.plaintiff,
            a.defendant,
            a.votingId
        );
    }

    function settleDispute(uint256 id) external onlyParties(id) {
        Agreement storage a = agreements[id];
        if (!a.disputed) revert NotYetOnDispute();
        if (msg.sender != a.plaintiff) revert NotParty();
        if (block.timestamp > a.disputeEndAt) revert VoteStarted();

        address _plaintiff = a.plaintiff;
        address _defendant = a.defendant;
        uint256 _votingId = a.votingId;

        a.disputed = false;
        a.frozen = false;
        a.disputeEndAt = 0;
        a.plaintiff = address(0);
        a.defendant = address(0);

        a.deliverySubmited = false;
        a.grace1Ends = 0;
        a.grace1EndsCalledBy = address(0);

        emit DisputeSettled(id, _plaintiff, _defendant, _votingId);
    }

    // ===================================================== //
    // ================== INTERNAL FUNDS OPS =============== //
    // ===================================================== //

    function _releaseFunds(
        Agreement storage a,
        uint256 toServiceRecipient,
        uint256 toServiceProvider,
        bool complete
    ) internal {
        address _token = address(a.token);
        address _serviceRecipient = address(a.serviceRecipient);
        address _serviceProvider = address(a.serviceProvider);
        uint256 _id = a.id;
        uint256 feeBp = _config.platformFeeBp;

        // validate amounts don't exceed remaining
        uint256 requested = toServiceRecipient + toServiceProvider;
        if (requested == 0) revert InvalidAmount();
        if (requested > a.remainingAmount) revert InvalidAmount();
        uint256 feeServiceRecipient = toServiceRecipient > 0
            ? (toServiceRecipient * feeBp) / DIV
            : 0;

        uint256 feeCounter = toServiceProvider > 0
            ? (toServiceProvider * feeBp) / DIV
            : 0;

        uint256 feeTotal = feeServiceRecipient + feeCounter;

        uint256 amountToServiceRecipient = toServiceRecipient >
            feeServiceRecipient
            ? toServiceRecipient - feeServiceRecipient
            : 0;

        uint256 amountToServiceProvider = toServiceProvider > feeCounter
            ? toServiceProvider - feeCounter
            : 0;

        // decrement remainingAmount immediately to prevent double-spend
        a.remainingAmount -= requested;

        if (feeTotal > 0) {
            totalFeesTaken += feeTotal;
        }

        if (complete || a.remainingAmount == 0) {
            a.completed = true;
            a.frozen = false;
            totalSmooth++;
        }

        if (_token == address(0)) {
            if (totalEscrowedEth >= requested) {
                totalEscrowedEth -= requested;
            }

            if (toServiceRecipient > 0) {
                (bool sent, ) = _serviceRecipient.call{
                    value: amountToServiceRecipient
                }("");
                if (!sent) {
                    pendingPayOut[
                        _serviceRecipient
                    ] += amountToServiceRecipient;
                }
            }
            if (toServiceProvider > 0) {
                (bool sent, ) = _serviceProvider.call{
                    value: amountToServiceProvider
                }("");
                if (!sent) {
                    pendingPayOut[_serviceProvider] += amountToServiceProvider;
                }
            }

            if (feeTotal > 0 && feeRecipient != address(0)) {
                (bool okFee, ) = payable(feeRecipient).call{value: feeTotal}(
                    ""
                );
                if (!okFee) {
                    pendingPayOut[feeRecipient] += feeTotal;
                }
            }
        } else {
            if (toServiceRecipient > 0) {
                IERC20(_token).safeTransfer(
                    _serviceRecipient,
                    amountToServiceRecipient
                );
            }
            if (toServiceProvider > 0) {
                IERC20(_token).safeTransfer(
                    _serviceProvider,
                    amountToServiceProvider
                );
            }

            if (feeTotal > 0 && feeRecipient != address(0)) {
                IERC20(_token).safeTransfer(feeRecipient, feeTotal);
            }
        }

        emit FundsReleased(
            _id,
            amountToServiceProvider,
            amountToServiceRecipient,
            feeTotal
        );

        if (complete || a.remainingAmount == 0) {
            emit AgreementCompleted(_id, a.disputed);
        }
    }

    // helper to configure milestones' absolute unlock times and validate they are within deadline
    function _configureMilestonesOnSign(uint256 id) internal {
        Agreement storage a = agreements[id];
        // require deadlineDuration > 0 when vesting is enabled
        if (a.deadlineDuration == 0) revert InvalidMilestoneConfig();

        uint256 len = _milestonePercBp[id].length;
        for (uint256 i = 0; i < len; i++) {
            uint256 offset = _milestoneOffsets[id][i];
            // unlock must not exceed deadlineDuration
            if (offset > a.deadlineDuration) revert InvalidMilestoneConfig();
            Milestone memory m = Milestone({
                percentBp: _milestonePercBp[id][i],
                unlockAt: block.timestamp + offset,
                heldByRecipient: false,
                claimed: false
            });
            _milestones[id].push(m);
        }

        emit VestingConfigured(id);
    }

    function _onlyParties(uint256 id) internal view {
        Agreement storage a = agreements[id];
        if (msg.sender != a.serviceProvider && msg.sender != a.serviceRecipient)
            revert NotParty();
    }

    function _onlyActive(uint256 id) internal view {
        Agreement storage a = agreements[id];
        if (a.completed) revert NotActive();
        if (a.frozen) revert NotActive();
    }

    function _onlyResolver() internal view {
        if (msg.sender != disputeResolver && msg.sender != owner())
            revert NotResolver();
    }

    // ===================================================== //
    // ===================== ADMIN OPS ===================== //
    // ===================================================== //

    /**
     * @notice Finalize a dispute after off-chain court/voting concludes.
     *
     * @param id                  Agreement id
     * @param outcome             Resolved | Dismissed | Dropped
     * @param toServiceProvider   Amount to provider (ignored if Dropped)
     * @param toServiceRecipient  Amount to recipient (ignored if Dropped)
     * @param votingId            Off-chain vote id
     */
    function finalizeDispute(
        uint256 id,
        DisputeOutcome outcome,
        uint256 toServiceProvider,
        uint256 toServiceRecipient,
        uint256 votingId
    ) external nonReentrant onlyResolver {
        Agreement storage a = agreements[id];
        if (!a.disputed) revert NotYetOnDispute();
        if (a.completed) revert NotActive();

        address _plaintiff = a.plaintiff;
        address _defendant = a.defendant;
        uint256 _votingId = a.votingId != 0 ? a.votingId : votingId;

        a.disputed = false;
        a.frozen = false;
        a.disputeEndAt = 0;
        a.plaintiff = address(0);
        a.defendant = address(0);

        if (outcome == DisputeOutcome.Dropped) {
            a.deliverySubmited = false;
            a.grace1Ends = 0;
            a.grace1EndsCalledBy = address(0);

            emit DisputeFinalized(
                id,
                outcome,
                _plaintiff,
                _defendant,
                0,
                0,
                _votingId
            );
            return;
        }

        uint256 total = toServiceProvider + toServiceRecipient;
        if (total == 0 || total != a.remainingAmount) revert InvalidAmount();

        emit DisputeFinalized(
            id,
            outcome,
            _plaintiff,
            _defendant,
            toServiceProvider,
            toServiceRecipient,
            _votingId
        );

        _releaseFunds(a, toServiceRecipient, toServiceProvider, true);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    function freezeAgreement(uint256 id, bool status) external onlyOwner {
        agreements[id].frozen = status;
        emit AgreementFrozen(id, status);
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
        emit StuckFundsRecovered(token, _amount);
    }

    // ===================================================== //
    // ===================== VIEW HELPERS ================== //
    // ===================================================== //

    function getStats()
        external
        view
        returns (
            uint256 agreementsTotal,
            uint256 disputesTotal,
            uint256 smoothTotal,
            uint256 feesTaken,
            uint256 escrowedEth,
            address _feeRecipient
        )
    {
        return (
            totalAgreements,
            totalDisputes,
            totalSmooth,
            totalFeesTaken,
            totalEscrowedEth,
            feeRecipient
        );
    }

    function getAgreement(
        uint256 id
    )
        external
        view
        returns (
            uint256 _id,
            address creator,
            address serviceProvider,
            address serviceRecipient,
            address token,
            uint256 amount,
            uint256 remainingAmount,
            uint256 createdAt,
            uint256 deadline,
            uint256 deadlineDuration,
            uint256 grace1Ends,
            uint256 grace2Ends,
            address grace1EndsCalledBy,
            address grace2EndsCalledBy,
            bool funded,
            bool signed,
            bool acceptedByServiceProvider,
            bool acceptedByServiceRecipient,
            bool completed,
            bool disputed,
            bool privateMode,
            bool frozen,
            bool pendingCancellation,
            bool orderCancelled,
            bool vesting,
            bool deliverySubmited,
            uint256 votingId,
            uint256 disputeEndAt,
            address plaintiff,
            address defendant
        )
    {
        Agreement storage a = agreements[id];
        address _token = address(a.token);
        return (
            a.id,
            a.creator,
            a.serviceProvider,
            a.serviceRecipient,
            _token,
            a.amount,
            a.remainingAmount,
            a.createdAt,
            a.deadline,
            a.deadlineDuration,
            a.grace1Ends,
            a.grace2Ends,
            a.grace1EndsCalledBy,
            a.grace2EndsCalledBy,
            a.funded,
            a.signed,
            a.acceptedByServiceProvider,
            a.acceptedByServiceRecipient,
            a.completed,
            a.disputed,
            a.privateMode,
            a.frozen,
            a.pendingCancellation,
            a.orderCancelled,
            a.vesting,
            a.deliverySubmited,
            a.votingId,
            a.disputeEndAt,
            a.plaintiff,
            a.defendant
        );
    }

    /// @notice Return the creators for a list of agreement ids.
    /// @dev If an id does not exist its creator will be address(0).
    function getCreatorsBatch(
        uint256[] calldata ids
    ) external view returns (address[] memory) {
        address[] memory creators = new address[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            Agreement storage a = agreements[ids[i]];
            if (a.createdAt != 0) {
                creators[i] = a.creator;
            } else {
                creators[i] = address(0);
            }
        }

        return creators;
    }

    receive() external payable {}
}
