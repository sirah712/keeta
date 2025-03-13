// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title WETH Interface
/// @notice Interface for interacting with Wrapped Ether (WETH) contract on Base network
/// @dev Minimal interface for WETH9 functionality required by this contract
interface IWETH {
    /// @notice Deposit ETH to receive WETH
    function deposit() external payable;
    /// @notice Transfer WETH to another address
    /// @param to Recipient address
    /// @param value Amount of WETH to transfer
    /// @return success Whether the transfer was successful
    function transfer(address to, uint256 value) external returns (bool);
    /// @notice Withdraw ETH from WETH
    /// @param amount Amount of WETH to withdraw
    function withdraw(uint256 amount) external;
    /// @notice Approve spender to transfer WETH
    /// @param spender Address to approve
    /// @param amount Amount to approve
    /// @return success Whether the approval was successful
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title Aerodrome Router Interface
/// @notice Interface for Aerodrome DEX router functionality on Base network
/// @dev Minimal interface required for liquidity pool operations
interface IAerodrome {
    /// @notice Add liquidity to an Aerodrome pool
    /// @param tokenA First token in the pair
    /// @param tokenB Second token in the pair
    /// @param stable Whether the pool is stable or volatile
    /// @param amountADesired Desired amount of tokenA
    /// @param amountBDesired Desired amount of tokenB
    /// @param amountAMin Minimum amount of tokenA (slippage protection)
    /// @param amountBMin Minimum amount of tokenB (slippage protection)
    /// @param to Address that will receive LP tokens
    /// @param deadline Timestamp after which the transaction will revert
    /// @return amountA Amount of tokenA actually added
    /// @return amountB Amount of tokenB actually added
    /// @return liquidity Amount of LP tokens minted
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Swaps an exact amount of tokens for another token through the path provided
    /// @param amountIn The amount of input tokens to send
    /// @param amountOutMin The minimum amount of output tokens to receive
    /// @param routes The array of routes to use for the swap
    /// @param to The address to receive the output tokens
    /// @param deadline The timestamp after which the transaction will revert
    /// @return amounts The amounts of tokens swapped at each hop
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Swaps an exact amount of ETH for tokens
    /// @param amountOutMin The minimum amount of output tokens to receive
    /// @param routes The array of routes to use for the swap
    /// @param to The address to receive the output tokens
    /// @param deadline The timestamp after which the transaction will revert
    /// @return amounts The amounts of tokens swapped at each hop
    function swapExactETHForTokens(
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    /// @notice Represents a single swap route
    /// @param from The address of the input token
    /// @param to The address of the output token
    /// @param stable Whether to use the stable or volatile pool
    /// @param factory The factory address for the pool
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    /// @notice Swaps exact eth or tokens supporting fee on transfer
    /// @param amountOutMin The minimum amount of output tokens to receive
    /// @param routes The array of routes to use for the swap
    /// @param to The address to receive the output tokens
    /// @param deadline The timestamp after which the transaction will revert
    /// @return amounts The amounts of tokens swapped at each hop
    function swapExactETHForTokensSupportingFeeOnTransfer(
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

/// @title Aerodrome Factory Interface
/// @notice Interface for creating and managing Aerodrome liquidity pools on Base network
/// @dev Minimal interface required for pool creation and querying
interface IAerodromeFactory {
    /// @notice Create a new liquidity pool
    /// @param tokenA First token in the pair
    /// @param tokenB Second token in the pair
    /// @param stable Whether to create a stable or volatile pool
    /// @return pair Address of the created pool
    function createPool(address tokenA, address tokenB, bool stable) external returns (address pair);
    /// @notice Get the address of an existing pool
    /// @param tokenA First token in the pair
    /// @param tokenB Second token in the pair
    /// @param stable Whether the pool is stable or volatile
    /// @return pool Address of the pool (zero address if it doesn't exist)
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}

/// @title Dynamic Tax Token with Liquidity Management
/// @notice Implementation of an ERC20 token with dynamic tax reduction and automated liquidity pool management
/// @dev Token implements a tax system that reduces over time and includes liquidity pool creation/management features.
/// The tax starts at an initial rate and reduces by a fixed percentage after an initial period.
/// Tax reduction occurs in steps: after the initial period 2minutes at 2 seconds per block, 
/// tax reduces by 1% every 30sec at 2 seconds per block until it reaches 0%.
contract Contract is ERC20, ERC20Permit, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Token metadata
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 private _totalSupply;

    // Protocol addresses
    /// @dev Address of the WETH contract on Base network
    address private immutable _WETH;
    /// @dev Address of the Aerodrome router contract
    address private immutable _ROUTER;
    /// @dev Address of the Aerodrome factory contract
    address private immutable _AERODROME_FACTORY;
    /// @dev Address of the token's liquidity pool (zero if not created)
    address public liquidityPool;

    // Tax parameters
    /// @dev Initial tax percentage (1-100)
    uint8 private immutable _initialTax;
    /// @dev Number of blocks between tax reductions
    uint256 private immutable _taxReductionInterval;
    /// @dev Number of blocks before tax reduction begins
    uint256 private immutable _initialTaxDuration;
    /// @dev Whether tax reduction has completed
    bool private _taxReductionComplete;
    /// @dev Address that receives tax payments
    address private immutable _taxRecipient;
    /// @dev Percentage points to reduce tax by each interval
    uint8 private immutable _taxReductionRate;
    /// @dev Block number when contract was deployed
    uint256 private immutable _deploymentBlock;

    // Custom events
    /// @notice Emitted when tax reduction reaches zero
    event TaxReductionCompleted();
    /// @notice Emitted when LP tokens are burned
    /// @param amount The amount of LP tokens burned
    event LPTokensBurned(uint256 amount);

    /// @notice Struct containing all parameters needed for contract initialization
    /// @dev Used to avoid stack too deep errors in constructor
    struct InitParams {
        /// @notice Token name
        string name;
        /// @notice Token symbol
        string symbol;
        /// @notice Token decimals (typically 18)
        uint8 decimals;
        /// @notice Total supply of tokens
        uint256 totalSupply;
        /// @notice Initial tax percentage (1-100)
        uint8 initialTax;
        /// @notice Number of blocks between tax reductions
        uint256 taxReductionInterval;
        /// @notice Number of blocks before tax reduction begins
        uint256 initialTaxDuration;
        /// @notice Percentage points to reduce tax by each interval
        uint8 taxReductionRate;
        /// @notice Address that receives tax payments
        address taxRecipient;
        /// @notice WETH contract address
        address weth;
        /// @notice Aerodrome router address
        address router;
        /// @notice Aerodrome factory address
        address factory;
        /// @notice Initial owner of the contract
        address owner;
    }

    /// @notice Initializes the contract with the specified parameters
    /// @param params Struct containing all initialization parameters
    /// @dev All tokens are initially minted to the contract itself
    constructor(InitParams memory params) 
        ERC20(params.name, params.symbol) 
        ERC20Permit(params.name)
        Ownable(params.owner) 
    {
        require(params.initialTax <= 100, "Tax cannot exceed 100%");
        require(params.taxRecipient != address(0), "Tax recipient cannot be zero address");
        require(params.weth != address(0), "WETH cannot be zero address");
        require(params.router != address(0), "Router cannot be zero address");
        require(params.factory != address(0), "Factory cannot be zero address");
        require(params.owner != address(0), "Owner cannot be zero address");

        _initialTax = params.initialTax;
        _taxReductionInterval = params.taxReductionInterval;
        _initialTaxDuration = params.initialTaxDuration;
        _taxReductionRate = params.taxReductionRate;
        _taxRecipient = params.taxRecipient;
        _deploymentBlock = block.number;

        _WETH = params.weth;
        _ROUTER = params.router;
        _AERODROME_FACTORY = params.factory;

        _mint(address(this), params.totalSupply);
    }

    /// @notice Creates a liquidity pool for the token with WETH pair, adds initial liquidity, sends all LP tokens to the tax recipient
    /// @dev Creates a volatile pool on Aerodrome
    /// @param ethAmount Amount of ETH to add as initial liquidity
    /// @param maxSlippage Maximum allowed slippage in basis points (1 = 0.01%, max 1000 = 10%)
    function createLiquidityPool(uint256 ethAmount, uint16 maxSlippage) external payable nonReentrant {
        // Checks
        require(msg.value == ethAmount, "Incorrect ETH amount");
        require(liquidityPool == address(0), "Liquidity pool already created");
        require(ethAmount > 0, "ETH amount must be > 0");
        require(maxSlippage > 0 && maxSlippage <= 1000, "Invalid slippage (1-1000)");

        // Use all available tokens
        uint256 tokenAmount = balanceOf(address(this));
        require(tokenAmount > 0, "No tokens available");

        // Calculate minimum amounts based on slippage tolerance
        uint256 minTokenAmount = tokenAmount * (10000 - maxSlippage) / 10000;
        uint256 minEthAmount = ethAmount * (10000 - maxSlippage) / 10000;

        // Effects - Pre-approve tokens before any external calls
        _approve(address(this), _ROUTER, tokenAmount);

        // Interactions - External calls after state changes
        // Check if pool exists
        address poolAddress = IAerodromeFactory(_AERODROME_FACTORY).getPool(address(this), _WETH, false);
        if (poolAddress == address(0)) {
            poolAddress = IAerodromeFactory(_AERODROME_FACTORY).createPool(address(this), _WETH, false);
            require(poolAddress != address(0), "Failed to create pool");
        }

        // Update state
        liquidityPool = poolAddress;

        // Wrap ETH and approve WETH
        IWETH(_WETH).deposit{ value: ethAmount }();
        IWETH(_WETH).approve(_ROUTER, ethAmount);

        // Add liquidity with slippage protection
        (uint256 amountTokenUsed, uint256 amountETHUsed,) = IAerodrome(_ROUTER).addLiquidity(
            address(this),
            _WETH,
            false, // not stable
            tokenAmount,
            ethAmount,
            minTokenAmount,
            minEthAmount,
            address(this),
            block.timestamp + 1 hours
        );

        require(amountTokenUsed >= minTokenAmount && amountETHUsed >= minEthAmount, "Slippage exceeded");

        // Send all LP tokens to the tax recipient
        uint256 lpBalance = IERC20(liquidityPool).balanceOf(address(this));
        require(lpBalance > 0, "No LP tokens to send");
        IERC20(liquidityPool).safeTransfer(_taxRecipient, lpBalance);
        emit LPTokensBurned(lpBalance);

    }

    /// @notice Implementation of tax on transfers
    /// @dev Calculates and applies tax on transfers when applicable
    /// @dev No tax on mints, burns, or transfers involving the contract itself
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount being transferred
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        _updateTaxReductionStatus();
        uint256 tax = getCurrentTax();

        if (tax > 0 && from != address(this) && to != address(this)) {
            uint256 taxAmount = (amount * tax) / 100;
            uint256 transferAmount = amount - taxAmount;

            super._update(from, _taxRecipient, taxAmount);
            super._update(from, to, transferAmount);
        } else {
            super._update(from, to, amount);
        }
    }

    /// @notice Safely approves spender to spend tokens on behalf of msg.sender
    /// @dev Requires previous allowance to be 0 or new allowance to be 0 for safety
    /// @param spender Address authorized to spend tokens
    /// @param amount Amount of tokens approved to spend
    /// @return success Whether the approval was successful
    function approve(address spender, uint256 amount) public override returns (bool) {
        require(amount == 0 || allowance(msg.sender, spender) == 0, "Unsafe allowance change");
        return super.approve(spender, amount);
    }

    /// @notice Safely increases the allowance granted to spender by the caller
    /// @dev Checks for allowance overflow
    /// @param spender Address authorized to spend tokens
    /// @param addedValue Amount to increase the allowance by
    /// @return success Whether the allowance was increased
    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        uint256 currentAllowance = allowance(msg.sender, spender);
        uint256 newAllowance = currentAllowance + addedValue;
        require(newAllowance >= currentAllowance, "Allowance overflow");
        _approve(msg.sender, spender, newAllowance);
        return true;
    }

    /// @notice Safely decreases the allowance granted to spender by the caller
    /// @dev Checks that decrease doesn't go below zero
    /// @param spender Address authorized to spend tokens
    /// @param subtractedValue Amount to decrease the allowance by
    /// @return success Whether the allowance was decreased
    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        uint256 currentAllowance = allowance(msg.sender, spender);
        require(subtractedValue <= currentAllowance, "Decreased allowance below zero");
        _approve(msg.sender, spender, currentAllowance - subtractedValue);
        return true;
    }

    /// @notice Updates the tax reduction status based on current block number
    /// @dev Sets _taxReductionComplete to true if tax has been fully reduced
    /// @dev Emits TaxReductionCompleted event when tax reaches zero
    function _updateTaxReductionStatus() private {
        if (!_taxReductionComplete && getCurrentTax() == 0) {
            _taxReductionComplete = true;
            emit TaxReductionCompleted();
        }
    }

    /// @notice Gets the current tax rate based on block number
    /// @dev Tax remains at initial rate during initial period, then reduces by taxReductionRate every interval
    /// @return Current tax rate as a percentage (0-100)
    function getCurrentTax() public view returns (uint8) {
        if (_taxReductionComplete) {
            return 0;
        }

        // During initial period, return initial tax
        if (block.number < _deploymentBlock + _initialTaxDuration) {
            return _initialTax;
        }

        // Calculate blocks since initial period ended
        uint256 blocksSinceInitialDuration = block.number - (_deploymentBlock + _initialTaxDuration);
        
        // Calculate number of reductions that have occurred
        uint256 reductions = blocksSinceInitialDuration / _taxReductionInterval;
        
        // Calculate current tax rate
        uint256 taxReduction = reductions * _taxReductionRate;
        if (taxReduction >= _initialTax) {
            return 0;
        }
        
        return uint8(_initialTax - taxReduction);
    }

    /// @notice Renounces ownership of the contract
    /// @dev Sets owner to address(0), making owner-only functions inaccessible
    /// @dev This action is irreversible
    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership();
    }

    /// @notice Handles incoming ETH transfers
    /// @dev Only accepts ETH from WETH contract
    receive() external payable {
        require(msg.sender == _WETH, "Only accept ETH from WETH");
    }

    /// @notice Fallback function to reject unexpected calls
    /// @dev Reverts all unexpected function calls
    fallback() external payable {
        revert("Function not found");
    }

    /// @notice Claims accumulated fees from the liquidity pool
    /// @dev Only callable by owner, sends claimed fees to tax recipient
    function claimPoolFees() external onlyOwner nonReentrant {
        require(liquidityPool != address(0), "Pool not created");
        
        // Get LP token balance
        uint256 lpBalance = IERC20(liquidityPool).balanceOf(address(this));
        require(lpBalance > 0, "No LP tokens held");

        // Interface for the pool
        IAerodromePool pool = IAerodromePool(liquidityPool);
        
        // Claim fees
        pool.claimFees();

        // Transfer any WETH received to tax recipient
        uint256 wethBalance = IERC20(_WETH).balanceOf(address(this));
        if (wethBalance > 0) {
            IERC20(_WETH).safeTransfer(_taxRecipient, wethBalance);
        }

        // Transfer any tokens received to tax recipient
        uint256 tokenBalance = balanceOf(address(this));
        if (tokenBalance > lpBalance) {
            uint256 excessTokens = tokenBalance - lpBalance;
            _transfer(address(this), _taxRecipient, excessTokens);
        }
    }
}

/// @title Aerodrome Pool Interface
/// @notice Minimal interface for Aerodrome pool fee claiming
interface IAerodromePool {
    /// @notice Claims accumulated fees from the pool
    function claimFees() external returns (uint256, uint256);
    /// @notice Returns the token0 address
    function token0() external view returns (address);
    /// @notice Returns the token1 address
    function token1() external view returns (address);
    /// @notice Returns the reserves of the pool
    function getReserves() external view returns (uint256, uint256, uint256);
    /// @notice Returns the stability of the pool
    function stable() external view returns (bool);
    /// @notice Returns the address of the factory
}
