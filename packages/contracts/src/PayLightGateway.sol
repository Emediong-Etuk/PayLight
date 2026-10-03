// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUSDT0} from "./interfaces/IUSDT0.sol";
import {ITapeOutProcessor, ITapeOutTransistors} from "./interfaces/ITapeOut.sol";
import {ICashbackRouter} from "./interfaces/ICashbackRouter.sol";

/// @title PayLightGateway
/// @notice Escrows USD₮0 for PayLight electricity orders on X Layer until the meter token is delivered, then settles
///         to the treasury, or refunds the payer. If PayLight disappears, payers can always reclaim their money
///         themselves once the order's refund deadline (fixed at payment time) has passed: `claimRefund`.
/// @dev    - No meter numbers, customer names or meter tokens are ever stored or emitted on-chain.
///         - Every order needs an EIP-712 quote signed by `quoteSigner`.
///         - The fee tier is computed ON-CHAIN by evaluating the "PayLight FeeTier v1" TapeOut circuit, and must equal
///           the quoted tier. The fee must equal the published bps for that tier (bounded by MAX_FEE_BPS), so even a
///           compromised quote signer cannot overcharge.
///         - TapeOut is upgradeable by third parties. Every TapeOut call is a gas-capped, return-size-capped
///           staticcall; any failure falls back to tier 0 (the default, highest published fee). TapeOut can never
///           block payments, settlement or refunds.
///         - Pausing blocks new payments only. Settlement, refunds and self-refunds keep working.
///         - Immutable (no proxy). Admin setters are bounded and emit events.
///         - Invariant: usdt0.balanceOf(this) >= totalPending.
contract PayLightGateway is AccessControl, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────── constants

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(bytes32 orderId,address payer,uint128 baseAmount,uint128 fee,uint8 tier,uint32 cashbackUnits,uint64 expiry)"
    );

    /// @notice Highest fee any tier can ever be set to: 2.00%.
    uint16 public constant MAX_FEE_BPS = 200;
    /// @notice Hard upper bound on transistor cashback per order.
    uint32 public constant MAX_CASHBACK_UNITS = 50;
    /// @notice Hard bounds for the pilot caps (USD₮0 has 6 decimals).
    uint128 public constant MAX_ORDER_HARD_CAP = 5_000e6;
    uint128 public constant MAX_DAILY_HARD_CAP = 100_000e6;
    uint64 public constant MIN_REFUND_TIMEOUT = 1 hours;
    uint64 public constant MAX_REFUND_TIMEOUT = 72 hours;

    /// @notice Number of fee tiers the FeeTier circuit can output (0, 1, 2).
    uint8 public constant TIER_COUNT = 3;
    uint256 internal constant NAND_ID = 0;
    uint256 internal constant LATCH_ID = 1;
    /// @dev Gas caps for calls into (upgradeable, third-party) TapeOut contracts.
    uint256 public constant EVAL_GAS_LIMIT = 300_000;
    uint256 public constant BALANCE_GAS_LIMIT = 100_000;

    // ─────────────────────────────────────────────────────────────── types

    enum Status {
        None,
        Paid,
        Fulfilled,
        Refunded
    }

    struct Order {
        address payer;
        uint64 paidAt;
        Status status;
        uint8 tier;
        bool cashbackCredited;
        uint128 amount; // total USD₮0 pulled = baseAmount + fee
        uint128 fee;
        uint64 refundableAt; // payer may self-refund strictly after this timestamp (snapshot at payment time)
        uint32 cashbackUnits;
    }

    /// @notice A price quote signed by the backend's quote signer.
    /// @param orderId       Random 32-byte id chosen by the backend; one order per id, ever.
    /// @param payer         The wallet whose USD₮0 pays for this order.
    /// @param baseAmount    USD₮0 (6 dp) covering the electricity itself.
    /// @param fee           USD₮0 (6 dp) service fee; must equal ceil(baseAmount * tierFeeBps[tier] / 10_000).
    /// @param tier          Fee tier the FeeTier circuit returns for `payer` at quote time.
    /// @param cashbackUnits NAND transistors credited as cashback on settlement (<= MAX_CASHBACK_UNITS).
    /// @param expiry        Unix timestamp after which the quote can no longer be used.
    struct Quote {
        bytes32 orderId;
        address payer;
        uint128 baseAmount;
        uint128 fee;
        uint8 tier;
        uint32 cashbackUnits;
        uint64 expiry;
    }

    /// @notice EIP-2612 permit signature for exactly `baseAmount + fee`, spender = this gateway.
    struct PermitSig {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice EIP-3009 ReceiveWithAuthorization signature for exactly `baseAmount + fee`, to = this gateway,
    ///         nonce = orderId.
    struct AuthorizationSig {
        uint256 validAfter;
        uint256 validBefore;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct InitParams {
        address usdt0;
        address processor;
        address admin;
        address operator;
        address treasury;
        address quoteSigner;
        uint256 feeCircuitId;
        uint16[3] tierFeeBps;
        uint128 tier1Holding;
        uint128 tier2Holding;
        uint32 repeatOrders;
        uint128 maxOrderAmount;
        uint128 dailyVolumeCap;
        uint64 refundTimeout;
    }

    // ─────────────────────────────────────────────────────────────── storage

    IERC20 public immutable usdt0;
    /// @notice The PayLight TapeOut processor.
    address public immutable processor;
    /// @notice The processor's ERC-1155 transistor contract.
    address public immutable transistors;

    mapping(bytes32 orderId => Order) internal _orders;
    /// @notice Number of settled (fulfilled) orders per payer, an input to the FeeTier circuit.
    mapping(address payer => uint32) public settledOrders;
    /// @notice Gross USD₮0 paid per UTC day (day = timestamp / 1 days).
    mapping(uint256 day => uint256) public dailyVolume;

    address public treasury;
    address public cashbackRouter;
    address public quoteSigner;

    /// @notice Circuit id of "PayLight FeeTier v1" on `processor`; 0 disables tiering (everyone is tier 0).
    uint256 public feeCircuitId;
    /// @notice FeeTier circuit inputs: h1 = held >= tier1Holding, h2 = held >= tier2Holding,
    ///         r = settledOrders >= repeatOrders. held = NAND + LATCH balance on `transistors`.
    uint128 public tier1Holding;
    uint128 public tier2Holding;
    uint32 public repeatOrders;
    uint16[3] internal _tierFeeBps;

    uint128 public maxOrderAmount;
    uint128 public dailyVolumeCap;
    uint64 public refundTimeout;

    /// @notice Sum of `amount` over all orders in Status.Paid.
    uint256 public totalPending;

    // ─────────────────────────────────────────────────────────────── events

    event OrderPaid(
        bytes32 indexed orderId,
        address indexed payer,
        uint128 amount,
        uint128 fee,
        uint8 tier,
        uint32 cashbackUnits,
        uint64 refundableAt
    );
    event OrderFulfilled(bytes32 indexed orderId, bytes32 receiptHash, uint32 cashbackUnits, bool cashbackCredited);
    event CashbackCreditRetried(bytes32 indexed orderId, bool credited);
    event OrderRefunded(bytes32 indexed orderId, address indexed payer, uint128 amount, bool byOperator);

    event TreasuryUpdated(address treasury);
    event QuoteSignerUpdated(address quoteSigner);
    event CashbackRouterUpdated(address cashbackRouter);
    event FeeCircuitUpdated(uint256 circuitId);
    event TierFeesUpdated(uint16 tier0Bps, uint16 tier1Bps, uint16 tier2Bps);
    event TierThresholdsUpdated(uint128 tier1Holding, uint128 tier2Holding, uint32 repeatOrders);
    event MaxOrderAmountUpdated(uint128 maxOrderAmount);
    event DailyVolumeCapUpdated(uint128 dailyVolumeCap);
    event RefundTimeoutUpdated(uint64 refundTimeout);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────── errors

    error ZeroAddress();
    error OrderExists();
    error QuoteExpired();
    error PayerMismatch();
    error InvalidSignature();
    error TierChanged(uint8 quoted, uint8 actual);
    error InvalidTier();
    error FeeMismatch(uint128 quoted, uint128 expected);
    error ZeroAmount();
    error OrderTooLarge();
    error DailyCapExceeded();
    error TooMuchCashback();
    error NotPaid();
    error NotPayer();
    error RefundTooEarly(uint64 refundableAt);
    error TransferMismatch();
    error InsufficientGasForTier();
    error OutOfBounds();
    error RescueExceedsExcess();
    error NotCreditable();

    // ─────────────────────────────────────────────────────────────── constructor

    constructor(InitParams memory p) EIP712("PayLightGateway", "1") {
        if (
            p.usdt0 == address(0) || p.processor == address(0) || p.admin == address(0) || p.treasury == address(0)
                || p.quoteSigner == address(0)
        ) revert ZeroAddress();

        usdt0 = IERC20(p.usdt0);
        processor = p.processor;
        address t = ITapeOutProcessor(p.processor).transistors();
        if (t == address(0)) revert ZeroAddress();
        transistors = t;

        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
        if (p.operator != address(0)) _grantRole(OPERATOR_ROLE, p.operator);

        treasury = p.treasury;
        quoteSigner = p.quoteSigner;
        emit TreasuryUpdated(p.treasury);
        emit QuoteSignerUpdated(p.quoteSigner);

        feeCircuitId = p.feeCircuitId;
        emit FeeCircuitUpdated(p.feeCircuitId);
        _setTierFees(p.tierFeeBps);
        _setTierThresholds(p.tier1Holding, p.tier2Holding, p.repeatOrders);
        _setMaxOrderAmount(p.maxOrderAmount);
        _setDailyVolumeCap(p.dailyVolumeCap);
        _setRefundTimeout(p.refundTimeout);
    }

    // ─────────────────────────────────────────────────────────────── pay

    /// @notice Pay for a quoted order with a prior USD₮0 approval of exactly `baseAmount + fee`.
    function pay(Quote calldata q, bytes calldata signature) external nonReentrant whenNotPaused {
        if (q.payer != msg.sender) revert PayerMismatch();
        uint128 amount = _validateAndRecord(q, signature);
        _pullFrom(msg.sender, amount);
    }

    /// @notice Pay with an EIP-2612 permit for exactly `baseAmount + fee` (one transaction, no separate approve).
    /// @dev The permit is wrapped in try/catch so a front-run permit (same signature submitted first) cannot grief the
    ///      payment; the subsequent transferFrom still requires sufficient allowance.
    function payWithPermit(Quote calldata q, bytes calldata signature, PermitSig calldata p)
        external
        nonReentrant
        whenNotPaused
    {
        if (q.payer != msg.sender) revert PayerMismatch();
        uint128 amount = _validateAndRecord(q, signature);
        try IUSDT0(address(usdt0)).permit(msg.sender, address(this), amount, p.deadline, p.v, p.r, p.s) {} catch {}
        _pullFrom(msg.sender, amount);
    }

    /// @notice Gasless payment: anyone (normally PayLight's relayer) submits the payer's EIP-3009
    ///         ReceiveWithAuthorization for exactly `baseAmount + fee`, with `nonce == orderId`.
    /// @dev    receiveWithAuthorization requires msg.sender == to (this contract), so the authorization can only ever
    ///         move funds into this gateway, for this order. A front-runner can only complete the same payment.
    function payWithAuthorization(Quote calldata q, bytes calldata signature, AuthorizationSig calldata a)
        external
        nonReentrant
        whenNotPaused
    {
        uint128 amount = _validateAndRecord(q, signature);
        _receiveWithAuthorization(q.payer, q.orderId, amount, a);
    }

    // ─────────────────────────────────────────────────────────────── settle / refund

    /// @notice Settle a delivered order: send its USD₮0 to the treasury and credit transistor cashback.
    /// @param receiptHash keccak256 of the bill provider's transaction id (never the meter token).
    /// @dev Works while paused. A failing cashback router never blocks settlement (see retryCashbackCredit).
    function markFulfilled(bytes32 orderId, bytes32 receiptHash) external nonReentrant onlyRole(OPERATOR_ROLE) {
        Order storage o = _orders[orderId];
        if (o.status != Status.Paid) revert NotPaid();
        o.status = Status.Fulfilled;
        uint128 amount = o.amount;
        totalPending -= amount;
        unchecked {
            settledOrders[o.payer] += 1;
        }

        usdt0.safeTransfer(treasury, amount);

        bool credited = _creditCashback(orderId, o);
        emit OrderFulfilled(orderId, receiptHash, o.cashbackUnits, credited);
    }

    /// @notice Retry crediting cashback for a fulfilled order whose credit failed (e.g. router unset or reverted).
    function retryCashbackCredit(bytes32 orderId) external nonReentrant onlyRole(OPERATOR_ROLE) {
        Order storage o = _orders[orderId];
        if (o.status != Status.Fulfilled || o.cashbackCredited || o.cashbackUnits == 0) revert NotCreditable();
        bool credited = _creditCashback(orderId, o);
        emit CashbackCreditRetried(orderId, credited);
    }

    /// @notice Operator refund of the full amount, e.g. after a definitive provider failure. Works while paused.
    function refund(bytes32 orderId) external nonReentrant onlyRole(OPERATOR_ROLE) {
        _refund(orderId, true);
    }

    /// @notice Payer self-refund of the full amount once the order's refund deadline has passed. Works while paused and
    ///         without any PayLight backend: this is the trust-minimising guarantee.
    function claimRefund(bytes32 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        if (o.status != Status.Paid) revert NotPaid();
        if (msg.sender != o.payer) revert NotPayer();
        if (block.timestamp <= o.refundableAt) revert RefundTooEarly(o.refundableAt);
        _refund(orderId, false);
    }

    // ─────────────────────────────────────────────────────────────── views

    function getOrder(bytes32 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function tierFeeBps(uint8 tier) public view returns (uint16) {
        if (tier >= TIER_COUNT) revert InvalidTier();
        return _tierFeeBps[tier];
    }

    /// @notice The exact fee the gateway will require for `baseAmount` at `tier`.
    function previewFee(uint128 baseAmount, uint8 tier) public view returns (uint128) {
        // Safe: bps <= MAX_FEE_BPS (2%), so the result is <= baseAmount and fits in uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(Math.mulDiv(baseAmount, tierFeeBps(tier), 10_000, Math.Rounding.Ceil));
    }

    /// @notice The fee tier the FeeTier circuit currently assigns to `payer` (what `pay*` will require).
    /// @dev Falls back to tier 0 if tiering is disabled or TapeOut misbehaves.
    function computeTier(address payer) public view returns (uint8) {
        uint256 circuitId = feeCircuitId;
        if (circuitId == 0) return 0;
        // Ensure a TapeOut failure is genuine, not caused by the caller starving the call of gas (EIP-150 63/64).
        if (gasleft() < ((EVAL_GAS_LIMIT + 2 * BALANCE_GAS_LIMIT) * 64) / 63 + 20_000) revert InsufficientGasForTier();

        uint256 held = _safeBalance(payer, NAND_ID) + _safeBalance(payer, LATCH_ID);
        uint8 input;
        if (held >= tier1Holding) input |= 1; // h1
        if (held >= tier2Holding) input |= 2; // h2
        if (settledOrders[payer] >= repeatOrders) input |= 4; // r
        return _evalTier(circuitId, input);
    }

    /// @notice The FeeTier circuit's input byte for `payer` (for transparency / debugging).
    function circuitInput(address payer) external view returns (uint8 input, uint256 held) {
        held = _safeBalance(payer, NAND_ID) + _safeBalance(payer, LATCH_ID);
        if (held >= tier1Holding) input |= 1;
        if (held >= tier2Holding) input |= 2;
        if (settledOrders[payer] >= repeatOrders) input |= 4;
    }

    /// @notice EIP-712 digest of a quote (lets the backend cross-check its signer).
    function quoteDigest(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(QUOTE_TYPEHASH, q.orderId, q.payer, q.baseAmount, q.fee, q.tier, q.cashbackUnits, q.expiry)
            )
        );
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ─────────────────────────────────────────────────────────────── admin

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setQuoteSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        quoteSigner = newSigner;
        emit QuoteSignerUpdated(newSigner);
    }

    /// @notice address(0) disables cashback crediting (orders still settle).
    function setCashbackRouter(address newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        cashbackRouter = newRouter;
        emit CashbackRouterUpdated(newRouter);
    }

    /// @notice 0 disables tiering (everyone is tier 0).
    function setFeeCircuit(uint256 circuitId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeCircuitId = circuitId;
        emit FeeCircuitUpdated(circuitId);
    }

    function setTierFees(uint16[3] calldata bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTierFees(bps);
    }

    function setTierThresholds(uint128 t1, uint128 t2, uint32 r) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTierThresholds(t1, t2, r);
    }

    function setMaxOrderAmount(uint128 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxOrderAmount(v);
    }

    function setDailyVolumeCap(uint128 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDailyVolumeCap(v);
    }

    /// @notice Applies to future orders only; existing orders keep their snapshotted refund deadline.
    function setRefundTimeout(uint64 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRefundTimeout(v);
    }

    /// @notice Operator (incident response) or admin can pause new payments. Only admin can unpause.
    function pause() external {
        if (!hasRole(OPERATOR_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, OPERATOR_ROLE);
        }
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Recover tokens sent here by mistake. For USD₮0, only the excess above `totalPending` can be taken.
    function rescueToken(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(usdt0)) {
            uint256 bal = usdt0.balanceOf(address(this));
            if (bal < totalPending || amount > bal - totalPending) revert RescueExceedsExcess();
        }
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ─────────────────────────────────────────────────────────────── internal

    function _validateAndRecord(Quote calldata q, bytes calldata signature) internal returns (uint128 amount) {
        amount = _checkQuote(q, signature);
        _record(q, amount);
    }

    /// @dev All checks for a new order; no state changes. Returns baseAmount + fee.
    function _checkQuote(Quote calldata q, bytes calldata signature) internal view returns (uint128 amount) {
        if (_orders[q.orderId].status != Status.None) revert OrderExists();
        if (block.timestamp > q.expiry) revert QuoteExpired();
        if (q.payer == address(0)) revert ZeroAddress();
        if (q.baseAmount == 0) revert ZeroAmount();
        if (q.cashbackUnits > MAX_CASHBACK_UNITS) revert TooMuchCashback();
        if (q.tier >= TIER_COUNT) revert InvalidTier();

        uint128 expectedFee = previewFee(q.baseAmount, q.tier);
        if (q.fee != expectedFee) revert FeeMismatch(q.fee, expectedFee);
        amount = q.baseAmount + q.fee; // checked: reverts on overflow
        if (amount > maxOrderAmount) revert OrderTooLarge();
        if (dailyVolume[block.timestamp / 1 days] + amount > dailyVolumeCap) revert DailyCapExceeded();

        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(quoteDigest(q), signature);
        if (err != ECDSA.RecoverError.NoError || signer != quoteSigner) revert InvalidSignature();

        uint8 actualTier = computeTier(q.payer);
        if (actualTier != q.tier) revert TierChanged(q.tier, actualTier);
    }

    /// @dev Effects for a validated order.
    function _record(Quote calldata q, uint128 amount) internal {
        dailyVolume[block.timestamp / 1 days] += amount;
        uint64 refundableAt = uint64(block.timestamp) + refundTimeout;
        Order storage o = _orders[q.orderId];
        o.payer = q.payer;
        o.paidAt = uint64(block.timestamp);
        o.status = Status.Paid;
        o.tier = q.tier;
        o.amount = amount;
        o.fee = q.fee;
        o.refundableAt = refundableAt;
        o.cashbackUnits = q.cashbackUnits;
        totalPending += amount;
        emit OrderPaid(q.orderId, q.payer, amount, q.fee, q.tier, q.cashbackUnits, refundableAt);
    }

    function _receiveWithAuthorization(address from, bytes32 nonce, uint128 amount, AuthorizationSig calldata a)
        internal
    {
        uint256 before = usdt0.balanceOf(address(this));
        IUSDT0(address(usdt0)).receiveWithAuthorization(
            from, address(this), amount, a.validAfter, a.validBefore, nonce, a.v, a.r, a.s
        );
        if (usdt0.balanceOf(address(this)) - before != amount) revert TransferMismatch();
    }

    function _pullFrom(address from, uint128 amount) internal {
        uint256 before = usdt0.balanceOf(address(this));
        usdt0.safeTransferFrom(from, address(this), amount);
        if (usdt0.balanceOf(address(this)) - before != amount) revert TransferMismatch();
    }

    function _refund(bytes32 orderId, bool byOperator) internal {
        Order storage o = _orders[orderId];
        if (o.status != Status.Paid) revert NotPaid();
        o.status = Status.Refunded;
        uint128 amount = o.amount;
        totalPending -= amount;
        usdt0.safeTransfer(o.payer, amount);
        emit OrderRefunded(orderId, o.payer, amount, byOperator);
    }

    function _creditCashback(bytes32 orderId, Order storage o) internal returns (bool credited) {
        address router = cashbackRouter;
        uint32 units = o.cashbackUnits;
        if (router == address(0) || units == 0) return false;
        try ICashbackRouter(router).credit(orderId, o.payer, units) {
            o.cashbackCredited = true;
            credited = true;
        } catch {}
    }

    /// @dev ERC-1155 balance via a gas-capped, return-size-capped staticcall; 0 on any failure.
    function _safeBalance(address account, uint256 id) internal view returns (uint256) {
        (bool ok, bytes memory ret, uint256 size) = _cappedStaticcall(
            transistors, BALANCE_GAS_LIMIT, abi.encodeCall(ITapeOutTransistors.balanceOf, (account, id)), 32
        );
        if (!ok || size < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Evaluates the FeeTier circuit. Expects ABI-encoded `bytes` with length >= 1; tier = low 2 bits of byte 0.
    ///      Returns 0 on any failure or out-of-range output.
    function _evalTier(uint256 circuitId, uint8 input) internal view returns (uint8) {
        (bool ok, bytes memory ret, uint256 size) = _cappedStaticcall(
            processor, EVAL_GAS_LIMIT, abi.encodeCall(ITapeOutProcessor.eval, (circuitId, abi.encodePacked(input))), 96
        );
        if (!ok || size < 96) return 0;
        uint256 offset;
        uint256 len;
        uint256 firstWord;
        assembly ("memory-safe") {
            offset := mload(add(ret, 0x20))
            len := mload(add(ret, 0x40))
            firstWord := mload(add(ret, 0x60))
        }
        if (offset != 0x20 || len == 0) return 0;
        uint8 tier = uint8(firstWord >> 248) & 0x03;
        return tier < TIER_COUNT ? tier : 0;
    }

    /// @dev staticcall with a gas cap that copies at most `maxRet` bytes of returndata (no returndata bombs).
    function _cappedStaticcall(address target, uint256 gasLimit, bytes memory data, uint256 maxRet)
        internal
        view
        returns (bool ok, bytes memory ret, uint256 size)
    {
        ret = new bytes(maxRet);
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(data, 0x20), mload(data), add(ret, 0x20), maxRet)
            size := returndatasize()
        }
    }

    function _setTierFees(uint16[3] memory bps) internal {
        // Each tier is bounded, and higher tiers are never more expensive than lower ones.
        if (bps[0] > MAX_FEE_BPS || bps[1] > bps[0] || bps[2] > bps[1]) revert OutOfBounds();
        _tierFeeBps = bps;
        emit TierFeesUpdated(bps[0], bps[1], bps[2]);
    }

    function _setTierThresholds(uint128 t1, uint128 t2, uint32 r) internal {
        if (t1 == 0 || t2 < t1 || r == 0) revert OutOfBounds();
        tier1Holding = t1;
        tier2Holding = t2;
        repeatOrders = r;
        emit TierThresholdsUpdated(t1, t2, r);
    }

    function _setMaxOrderAmount(uint128 v) internal {
        if (v == 0 || v > MAX_ORDER_HARD_CAP) revert OutOfBounds();
        maxOrderAmount = v;
        emit MaxOrderAmountUpdated(v);
    }

    function _setDailyVolumeCap(uint128 v) internal {
        if (v == 0 || v > MAX_DAILY_HARD_CAP) revert OutOfBounds();
        dailyVolumeCap = v;
        emit DailyVolumeCapUpdated(v);
    }

    function _setRefundTimeout(uint64 v) internal {
        if (v < MIN_REFUND_TIMEOUT || v > MAX_REFUND_TIMEOUT) revert OutOfBounds();
        refundTimeout = v;
        emit RefundTimeoutUpdated(v);
    }
}
