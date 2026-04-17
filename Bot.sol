// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

// Bot Version 3.18

// Tiny ERC20 surface area used by this contract.
interface IERC20Minimal {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address recipient, uint256 value)
        external
        returns (bool);
    function approve(address spender, uint256 value)
        external
        returns (bool);
}

// Aave V3 pool entry point for a single-asset flash borrow.
interface IAaveSimplePool {
    function flashLoanSimple(
        address receiver,
        address asset,
        uint256 amount,
        bytes calldata data,
        uint16 referralCode
    ) external;
}

// Callback shape expected by Aave for flash loan receivers.
interface IAaveSimpleFlashBorrower {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata data
    ) external returns (bool);
}

// Uniswap V2-style router function used for both swap legs.
interface IRouterV2Like {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 minAmountOut,
        address[] calldata route,
        address recipient,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

// ERC20 helper logic for tokens with inconsistent return behavior.
library TokenOps {
    error TokenCallReverted(address token);
    error TokenCallReturnedFalse(address token);

    // Move tokens out of the contract safely.
    function safeSend(
        IERC20Minimal token,
        address recipient,
        uint256 value
    ) internal {
        _invoke(
            token,
            abi.encodeWithSelector(token.transfer.selector, recipient, value)
        );
    }

    // Set allowance, retrying with a reset-to-zero flow if needed.
    function safeApproveExact(
        IERC20Minimal token,
        address spender,
        uint256 value
    ) internal {
        bytes memory payload = abi.encodeWithSelector(
            token.approve.selector,
            spender,
            value
        );

        if (!_invokeBool(token, payload)) {
            _invoke(
                token,
                abi.encodeWithSelector(token.approve.selector, spender, 0)
            );
            _invoke(token, payload);
        }
    }

    // Low-level token call that accepts empty return data or true.
    function _invoke(IERC20Minimal token, bytes memory payload) private {
        (bool ok, bytes memory ret) = address(token).call(payload);
        if (!ok) revert TokenCallReverted(address(token));

        if (ret.length > 0 && !abi.decode(ret, (bool))) {
            revert TokenCallReturnedFalse(address(token));
        }
    }

    // Same idea as _invoke, but reports success/failure as a bool.
    function _invokeBool(IERC20Minimal token, bytes memory payload)
        private
        returns (bool)
    {
        (bool ok, bytes memory ret) = address(token).call(payload);
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}

// Two-leg flash-loan arbitrage executor.
contract HonestFlashArbV2 is IAaveSimpleFlashBorrower {
    using TokenOps for IERC20Minimal;

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error BadPlan();
    error BadCallback();
    error LoanAlreadyOpen();
    error NoLoanOpen();
    error RouterNotAllowed(address router);
    error TokenNotAllowed(address token);
    error GainTooSmall();
    error ContractPaused();
    error MustBePaused();
    error NativeTransfersDisabled();

    // Swap recipe decoded inside the Aave callback.
    struct ArbPlan {
        address router1;
        address router2;
        address[] path1;
        address[] path2;
        uint256 amountOutMin1;
        uint256 amountOutMin2;
        uint256 minProfit;
        uint256 deadline;
    }

    // Permanent config.
    address public immutable owner;
    address public immutable pool;

    // Runtime switches.
    bool public paused;
    bool public loanOpen;

    // Allowed routers and tradable tokens.
    mapping(address => bool) public routerWhitelist;
    mapping(address => bool) public tokenWhitelist;

    // Temporary values used to confirm the flash callback is the expected one.
    bytes32 public activePlanHash;
    address public activeAsset;
    uint256 public activeAmount;
    uint256 public balanceBefore;

    event PauseStatusChanged(bool isPaused);
    event FlashRequested(address indexed asset, uint256 amount);
    event FlashCompleted(
        address indexed asset,
        uint256 amount,
        uint256 premium,
        uint256 profit
    );
    event TokenRecovered(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier whenRunning() {
        if (paused) revert ContractPaused();
        _;
    }

    // Seed the contract with trusted router and token lists.
    constructor(
        address pool_,
        address[] memory routers,
        address[] memory tokens
    ) {
        if (pool_ == address(0)) revert ZeroAddress();

        owner = msg.sender;
        pool = pool_;

        for (uint256 i = 0; i < routers.length; ) {
            address r = routers[i];
            if (r == address(0)) revert ZeroAddress();
            routerWhitelist[r] = true;

            unchecked {
                ++i;
            }
        }

        for (uint256 i = 0; i < tokens.length; ) {
            address t = tokens[i];
            if (t == address(0)) revert ZeroAddress();
            tokenWhitelist[t] = true;

            unchecked {
                ++i;
            }
        }
    }

    // Stop strategy execution.
    function pause() external onlyOwner {
        paused = true;
        emit PauseStatusChanged(true);
    }

    // Re-enable strategy execution.
    function unpause() external onlyOwner {
        paused = false;
        emit PauseStatusChanged(false);
    }

    // Begin the flash loan after checking the proposed trade plan.
    function startArbitrage(
        address asset,
        uint256 amount,
        ArbPlan calldata plan
    ) external onlyOwner whenRunning {
        if (loanOpen) revert LoanAlreadyOpen();
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _checkPlan(asset, plan);

        uint256 startingBalance =
            IERC20Minimal(asset).balanceOf(address(this));
        bytes memory encodedPlan = abi.encode(plan);

        loanOpen = true;
        activePlanHash = keccak256(encodedPlan);
        activeAsset = asset;
        activeAmount = amount;
        balanceBefore = startingBalance;

        emit FlashRequested(asset, amount);

        IAaveSimplePool(pool).flashLoanSimple(
            address(this),
            asset,
            amount,
            encodedPlan,
            0
        );

        // If the callback was valid, it should have cleared the in-flight state.
        if (loanOpen) revert BadCallback();
    }

    // Aave calls this after transferring the borrowed funds.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata data
    ) external override whenRunning returns (bool) {
        if (msg.sender != pool) revert BadCallback();
        if (initiator != address(this)) revert BadCallback();
        if (!loanOpen) revert NoLoanOpen();

        if (asset != activeAsset || amount != activeAmount) {
            revert BadCallback();
        }

        if (keccak256(data) != activePlanHash) revert BadCallback();

        ArbPlan memory plan = abi.decode(data, (ArbPlan));
        _checkPlan(asset, plan);

        uint256 currentBalance = IERC20Minimal(asset).balanceOf(address(this));
        if (currentBalance < balanceBefore + amount) revert BadCallback();

        // First leg: borrowed asset -> bridge token.
        IERC20Minimal(asset).safeApproveExact(plan.router1, amount);

        uint256[] memory firstSwap = IRouterV2Like(plan.router1)
            .swapExactTokensForTokens(
                amount,
                plan.amountOutMin1,
                plan.path1,
                address(this),
                plan.deadline
            );

        IERC20Minimal(asset).safeApproveExact(plan.router1, 0);

        uint256 bridgeAmount = firstSwap[firstSwap.length - 1];
        address bridgeToken = plan.path1[plan.path1.length - 1];

        // Second leg: bridge token -> original borrowed asset.
        IERC20Minimal(bridgeToken).safeApproveExact(
            plan.router2,
            bridgeAmount
        );

        IRouterV2Like(plan.router2).swapExactTokensForTokens(
            bridgeAmount,
            plan.amountOutMin2,
            plan.path2,
            address(this),
            plan.deadline
        );

        IERC20Minimal(bridgeToken).safeApproveExact(plan.router2, 0);

        uint256 debt = amount + premium;
        uint256 endingBalance = IERC20Minimal(asset).balanceOf(address(this));

        if (endingBalance < balanceBefore + debt + plan.minProfit) {
            revert GainTooSmall();
        }

        uint256 profit = endingBalance - balanceBefore - debt;

        _resetLoanState();

        // Let Aave pull back principal plus fee.
        IERC20Minimal(asset).safeApproveExact(pool, debt);

        emit FlashCompleted(asset, amount, premium, profit);
        return true;
    }

    // Owner rescue path, available only while halted.
    function sweepToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (!paused) revert MustBePaused();
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20Minimal(token).safeSend(to, amount);
        emit TokenRecovered(token, to, amount);
    }

    // Validate routers, token paths, minimums, and expiry.
    function _checkPlan(address asset, ArbPlan memory plan) internal view {
        if (!tokenWhitelist[asset]) revert TokenNotAllowed(asset);

        if (!routerWhitelist[plan.router1]) {
            revert RouterNotAllowed(plan.router1);
        }

        if (!routerWhitelist[plan.router2]) {
            revert RouterNotAllowed(plan.router2);
        }

        if (plan.path1.length < 2 || plan.path2.length < 2) {
            revert BadPlan();
        }

        if (plan.path1[0] != asset) revert BadPlan();
        if (plan.path2[plan.path2.length - 1] != asset) revert BadPlan();

        address bridgeA = plan.path1[plan.path1.length - 1];
        address bridgeB = plan.path2[0];
        if (bridgeA != bridgeB) revert BadPlan();

        if (
            plan.amountOutMin1 == 0
                || plan.amountOutMin2 == 0
                || plan.minProfit == 0
        ) {
            revert BadPlan();
        }

        if (block.timestamp > plan.deadline) revert BadPlan();

        _checkWhitelistedPath(plan.path1);
        _checkWhitelistedPath(plan.path2);
    }

    // Every token in each route must be approved beforehand.
    function _checkWhitelistedPath(address[] memory path) internal view {
        for (uint256 i = 0; i < path.length; ) {
            address token = path[i];
            if (!tokenWhitelist[token]) revert TokenNotAllowed(token);

            unchecked {
                ++i;
            }
        }
    }

    // Clear temporary flash-loan bookkeeping.
    function _resetLoanState() internal {
        loanOpen = false;
        activePlanHash = bytes32(0);
        activeAsset = address(0);
        activeAmount = 0;
        balanceBefore = 0;
    }

    // Native coin deposits are intentionally unsupported.
    receive() external payable {
        revert NativeTransfersDisabled();
    }

    // Unknown calls and raw native transfers are both rejected.
    fallback() external payable {
        revert NativeTransfersDisabled();
    }
}
