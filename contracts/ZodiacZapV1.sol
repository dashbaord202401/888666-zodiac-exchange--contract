// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {IZodiacPair} from "./interfaces/IZodiacPair.sol";
import {IZodiacRouter02} from "./interfaces/IZodiacRouter02.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {Babylonian} from "./libraries/Babylonian.sol";

/*
 * @author Inspiration from the work of Zapper and Beefy.
 * Implemented and modified by ZodiacSwap teams.
 */
contract ZodiacZapV1 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Interface for Wrapped VIC (WVIC)
    IWETH public WVIC;

    // ZodiacRouter interface
    IZodiacRouter02 public zodiacRouter;

    // Maximum integer (used for managing allowance)
    uint256 public constant MAX_INT = 2**256 - 1;

    // Minimum amount for a swap (derived from ZodiacSwap)
    uint256 public constant MINIMUM_AMOUNT = 1000;

    // Maximum reverse zap ratio (100 --> 1%, 1000 --> 0.1%)
    uint256 public maxZapReverseRatio;

    // Address ZodiacRouter
    address private zodiacRouterAddress;

    // Address Wrapped VIC (WVIC)
    address private WVICAddress;

    // Owner recovers token
    event AdminTokenRecovery(address indexed tokenAddress, uint256 amountTokens);

    // Owner changes the maxZapReverseRatio
    event NewMaxZapReverseRatio(uint256 maxZapReverseRatio);

    // tokenToZap = 0x00 address if VIC
    event ZapIn(
        address indexed tokenToZap,
        address indexed lpToken,
        uint256 tokenAmountIn,
        uint256 lpTokenAmountReceived,
        address indexed user
    );

    // token0ToZap = 0x00 address if VIC
    event ZapInRebalancing(
        address indexed token0ToZap,
        address indexed token1ToZap,
        address lpToken,
        uint256 token0AmountIn,
        uint256 token1AmountIn,
        uint256 lpTokenAmountReceived,
        address indexed user
    );

    // tokenToReceive = 0x00 address if VIC
    event ZapOut(
        address indexed lpToken,
        address indexed tokenToReceive,
        uint256 lpTokenAmount,
        uint256 tokenAmountReceived,
        address indexed user
    );

    /*
     * @notice Fallback for WVIC
     */
    receive() external payable {
        assert(msg.sender == WVICAddress);
    }

    /*
     * @notice Constructor
     * @param _WVICAddress: address of the WVIC contract
     * @param _zodiacRouter: address of the ZodiacRouter
     * @param _maxZapReverseRatio: maximum zap ratio
     */
    constructor(
        address _WVICAddress,
        address _zodiacRouter,
        uint256 _maxZapReverseRatio
    ) {
        WVICAddress = _WVICAddress;
        WVIC = IWETH(_WVICAddress);
        zodiacRouterAddress = _zodiacRouter;
        zodiacRouter = IZodiacRouter02(_zodiacRouter);
        maxZapReverseRatio = _maxZapReverseRatio;
    }

    /*
     * @notice Zap VIC in a WVIC pool (e.g. WVIC/token)
     * @param _lpToken: LP token address (e.g. ZODIAC/VIC)
     * @param _tokenAmountOutMin: minimum token amount (e.g. ZODIAC) to receive in the intermediary swap (e.g. VIC --> ZODIAC)
     */
    function zapInVIC(address _lpToken, uint256 _tokenAmountOutMin) external payable nonReentrant {
        WVIC.deposit{value: msg.value}();

        // Call zap function
        uint256 lpTokenAmountTransferred = _zapIn(WVICAddress, msg.value, _lpToken, _tokenAmountOutMin);

        // Emit event
        emit ZapIn(
            address(0x0000000000000000000000000000000000000000),
            _lpToken,
            msg.value,
            lpTokenAmountTransferred,
            address(msg.sender)
        );
    }

    /*
     * @notice Zap a token in (e.g. token/other token)
     * @param _tokenToZap: token to zap
     * @param _tokenAmountIn: amount of token to swap
     * @param _lpToken: LP token address (e.g. ZODIAC/BUSD)
     * @param _tokenAmountOutMin: minimum token to receive (e.g. ZODIAC) in the intermediary swap (e.g. BUSD --> ZODIAC)
     */
    function zapInToken(
        address _tokenToZap,
        uint256 _tokenAmountIn,
        address _lpToken,
        uint256 _tokenAmountOutMin
    ) external nonReentrant {
        // Transfer tokens to this contract
        IERC20(_tokenToZap).safeTransferFrom(address(msg.sender), address(this), _tokenAmountIn);

        // Call zap function
        uint256 lpTokenAmountTransferred = _zapIn(_tokenToZap, _tokenAmountIn, _lpToken, _tokenAmountOutMin);

        // Emit event
        emit ZapIn(_tokenToZap, _lpToken, _tokenAmountIn, lpTokenAmountTransferred, address(msg.sender));
    }

    /*
     * @notice Zap two tokens in, rebalance them to 50-50, before adding them to LP
     * @param _token0ToZap: address of token0 to zap
     * @param _token1ToZap: address of token1 to zap
     * @param _token0AmountIn: amount of token0 to zap
     * @param _token1AmountIn: amount of token1 to zap
     * @param _lpToken: LP token address (token0/token1)
     * @param _tokenAmountInMax: maximum token amount to sell (in token to sell in the intermediary swap)
     * @param _tokenAmountOutMin: minimum token to receive in the intermediary swap
     * @param _isToken0Sold: whether token0 is expected to be sold (if false, sell token1)
     */
    function zapInTokenRebalancing(
        address _token0ToZap,
        address _token1ToZap,
        uint256 _token0AmountIn,
        uint256 _token1AmountIn,
        address _lpToken,
        uint256 _tokenAmountInMax,
        uint256 _tokenAmountOutMin,
        bool _isToken0Sold
    ) external nonReentrant {
        // Transfer tokens to this contract
        IERC20(_token0ToZap).safeTransferFrom(address(msg.sender), address(this), _token0AmountIn);
        IERC20(_token1ToZap).safeTransferFrom(address(msg.sender), address(this), _token1AmountIn);

        // Call zapIn function
        uint256 lpTokenAmountTransferred = _zapInRebalancing(
            _token0ToZap,
            _token1ToZap,
            _token0AmountIn,
            _token1AmountIn,
            _lpToken,
            _tokenAmountInMax,
            _tokenAmountOutMin,
            _isToken0Sold
        );

        // Emit event
        emit ZapInRebalancing(
            _token0ToZap,
            _token1ToZap,
            _lpToken,
            _token0AmountIn,
            _token1AmountIn,
            lpTokenAmountTransferred,
            address(msg.sender)
        );
    }

    /*
     * @notice Zap 1 token and VIC, rebalance them to 50-50, before adding them to LP
     * @param _token1ToZap: address of token1 to zap
     * @param _token1AmountIn: amount of token1 to zap
     * @param _lpToken: LP token address
     * @param _tokenAmountInMax: maximum token amount to sell (in token to sell in the intermediary swap)
     * @param _tokenAmountOutMin: minimum token to receive in the intermediary swap
     * @param _isToken0Sold: whether token0 is expected to be sold (if false, sell token1)
     */
    function zapInVICRebalancing(
        address _token1ToZap,
        uint256 _token1AmountIn,
        address _lpToken,
        uint256 _tokenAmountInMax,
        uint256 _tokenAmountOutMin,
        bool _isToken0Sold
    ) external payable nonReentrant {
        WVIC.deposit{value: msg.value}();

        IERC20(_token1ToZap).safeTransferFrom(address(msg.sender), address(this), _token1AmountIn);

        // Call zapIn function
        uint256 lpTokenAmountTransferred = _zapInRebalancing(
            WVICAddress,
            _token1ToZap,
            msg.value,
            _token1AmountIn,
            _lpToken,
            _tokenAmountInMax,
            _tokenAmountOutMin,
            _isToken0Sold
        );

        // Emit event
        emit ZapInRebalancing(
            address(0x0000000000000000000000000000000000000000),
            _token1ToZap,
            _lpToken,
            msg.value,
            _token1AmountIn,
            lpTokenAmountTransferred,
            address(msg.sender)
        );
    }

    /*
     * @notice Zap a LP token out to receive VIC
     * @param _lpToken: LP token address (e.g. ZODIAC/WVIC)
     * @param _lpTokenAmount: amount of LP tokens to zap out
     * @param _tokenAmountOutMin: minimum amount to receive (in VIC/WVIC) in the intermediary swap (e.g. ZODIAC --> VIC)
     */
    function zapOutVIC(
        address _lpToken,
        uint256 _lpTokenAmount,
        uint256 _tokenAmountOutMin
    ) external nonReentrant {
        // Transfer LP token to this address
        IERC20(_lpToken).safeTransferFrom(address(msg.sender), address(_lpToken), _lpTokenAmount);

        // Call zapOut
        uint256 tokenAmountToTransfer = _zapOut(_lpToken, WVICAddress, _tokenAmountOutMin);

        // Unwrap VIC
        WVIC.withdraw(tokenAmountToTransfer);

        // Transfer VIC to the msg.sender
        (bool success, ) = msg.sender.call{value: tokenAmountToTransfer}(new bytes(0));
        require(success, "VIC: transfer fail");

        // Emit event
        emit ZapOut(
            _lpToken,
            address(0x0000000000000000000000000000000000000000),
            _lpTokenAmount,
            tokenAmountToTransfer,
            address(msg.sender)
        );
    }

    /*
     * @notice Zap a LP token out (to receive a token)
     * @param _lpToken: LP token address (e.g. ZODIAC/BUSD)
     * @param _tokenToReceive: one of the 2 tokens from the LP (e.g. ZODIAC or BUSD)
     * @param _lpTokenAmount: amount of LP tokens to zap out
     * @param _tokenAmountOutMin: minimum token to receive (e.g. ZODIAC) in the intermediary swap (e.g. BUSD --> ZODIAC)
     */
    function zapOutToken(
        address _lpToken,
        address _tokenToReceive,
        uint256 _lpTokenAmount,
        uint256 _tokenAmountOutMin
    ) external nonReentrant {
        // Transfer LP token to this address
        IERC20(_lpToken).safeTransferFrom(address(msg.sender), address(_lpToken), _lpTokenAmount);

        uint256 tokenAmountToTransfer = _zapOut(_lpToken, _tokenToReceive, _tokenAmountOutMin);

        IERC20(_tokenToReceive).safeTransfer(address(msg.sender), tokenAmountToTransfer);

        emit ZapOut(_lpToken, _tokenToReceive, _lpTokenAmount, tokenAmountToTransfer, msg.sender);
    }

    /**
     * @notice It allows the owner to change the risk parameter for quantities
     * @param _maxZapInverseRatio: new inverse ratio
     * @dev This function is only callable by owner.
     */
    function updateMaxZapInverseRatio(uint256 _maxZapInverseRatio) external onlyOwner {
        maxZapReverseRatio = _maxZapInverseRatio;
        emit NewMaxZapReverseRatio(_maxZapInverseRatio);
    }

    /**
     * @notice It allows the owner to recover wrong tokens sent to the contract
     * @param _tokenAddress: the address of the token to withdraw (18 decimals)
     * @param _tokenAmount: the number of token amount to withdraw
     * @dev This function is only callable by owner.
     */
    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        IERC20(_tokenAddress).safeTransfer(address(msg.sender), _tokenAmount);
        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    /*
     * @notice View the details for single zap
     * @dev Use WVIC for _tokenToZap (if VIC is the input)
     * @param _tokenToZap: address of the token to zap
     * @param _tokenAmountIn: amount of token to zap inputed
     * @param _lpToken: address of the LP token
     * @return swapAmountIn: amount that is expected to get swapped in intermediary swap
     * @return swapAmountOut: amount that is expected to get received in intermediary swap
     * @return swapTokenOut: token address of the token that is used in the intermediary swap
     */
    function estimateZapInSwap(
        address _tokenToZap,
        uint256 _tokenAmountIn,
        address _lpToken
    )
        external
        view
        returns (
            uint256 swapAmountIn,
            uint256 swapAmountOut,
            address swapTokenOut
        )
    {
        address token0 = IZodiacPair(_lpToken).token0();
        address token1 = IZodiacPair(_lpToken).token1();

        require(_tokenToZap == token0 || _tokenToZap == token1, "Zap: Wrong tokens");

        // Convert to uint256 (from uint112)
        (uint256 reserveA, uint256 reserveB, ) = IZodiacPair(_lpToken).getReserves();

        if (token0 == _tokenToZap) {
            swapTokenOut = token1;
            swapAmountIn = _calculateAmountToSwap(_tokenAmountIn, reserveA, reserveB);
            swapAmountOut = zodiacRouter.getAmountOut(swapAmountIn, reserveA, reserveB);
        } else {
            swapTokenOut = token0;
            swapAmountIn = _calculateAmountToSwap(_tokenAmountIn, reserveB, reserveA);
            swapAmountOut = zodiacRouter.getAmountOut(swapAmountIn, reserveB, reserveA);
        }

        return (swapAmountIn, swapAmountOut, swapTokenOut);
    }

    /*
     * @notice View the details for a rebalancing zap
     * @dev Use WVIC for _token0ToZap (if VIC is the input)
     * @param _token0ToZap: address of the token0 to zap
     * @param _token1ToZap: address of the token0 to zap
     * @param _token0AmountIn: amount for token0 to zap
     * @param _token1AmountIn: amount for token1 to zap
     * @param _lpToken: address of the LP token
     * @return swapAmountIn: amount that is expected to get swapped in intermediary swap
     * @return swapAmountOut: amount that is expected to get received in intermediary swap
     * @return isToken0Sold: whether the token0 is sold (false --> token1 is sold in the intermediary swap)
     */
    function estimateZapInRebalancingSwap(
        address _token0ToZap,
        address _token1ToZap,
        uint256 _token0AmountIn,
        uint256 _token1AmountIn,
        address _lpToken
    )
        external
        view
        returns (
            uint256 swapAmountIn,
            uint256 swapAmountOut,
            bool sellToken0
        )
    {
        require(
            _token0ToZap == IZodiacPair(_lpToken).token0() || _token0ToZap == IZodiacPair(_lpToken).token1(),
            "Zap: Wrong token0"
        );
        require(
            _token1ToZap == IZodiacPair(_lpToken).token0() || _token1ToZap == IZodiacPair(_lpToken).token1(),
            "Zap: Wrong token1"
        );

        require(_token0ToZap != _token1ToZap, "Zap: Same tokens");

        // Convert to uint256 (from uint112)
        (uint256 reserveA, uint256 reserveB, ) = IZodiacPair(_lpToken).getReserves();

        if (_token0ToZap == IZodiacPair(_lpToken).token0()) {
            sellToken0 = (_token0AmountIn * reserveB > _token1AmountIn * reserveA) ? true : false;

            // Calculate the amount that is expected to be swapped
            swapAmountIn = _calculateAmountToSwapForRebalancing(
                _token0AmountIn,
                _token1AmountIn,
                reserveA,
                reserveB,
                sellToken0
            );

            // Calculate the amount expected to be received in the intermediary swap
            if (sellToken0) {
                swapAmountOut = zodiacRouter.getAmountOut(swapAmountIn, reserveA, reserveB);
            } else {
                swapAmountOut = zodiacRouter.getAmountOut(swapAmountIn, reserveB, reserveA);
            }
        } else {
            sellToken0 = (_token0AmountIn * reserveA > _token1AmountIn * reserveB) ? true : false;
            // Calculate the amount that is expected to be swapped
            swapAmountIn = _calculateAmountToSwapForRebalancing(
                _token0AmountIn,
                _token1AmountIn,
                reserveB,
                reserveA,
                sellToken0
            );

            // Calculate the amount expected to be received in the intermediary swap
            if (sellToken0) {
                swapAmountOut = zodiacRouter.getAmountOut(swapAmountIn, reserveB, reserveA);
            } else {
                swapAmountOut = zodiacRouter.getAmountOut(swapAmountIn, reserveA, reserveB);
            }
        }

        return (swapAmountIn, swapAmountOut, sellToken0);
    }

    /*
     * @notice View the details for single zap
     * @dev Use WVIC for _tokenToReceive (if VIC is the asset to be received)
     * @param _lpToken: address of the LP token to zap out
     * @param _lpTokenAmount: amount of LP token to zap out
     * @param _tokenToReceive: token address to receive
     * @return swapAmountIn: amount that is expected to get swapped for intermediary swap
     * @return swapAmountOut: amount that is expected to get received for intermediary swap
     * @return swapTokenOut: address of the token that is sold in the intermediary swap
     */
    function estimateZapOutSwap(
        address _lpToken,
        uint256 _lpTokenAmount,
        address _tokenToReceive
    )
        external
        view
        returns (
            uint256 swapAmountIn,
            uint256 swapAmountOut,
            address swapTokenOut
        )
    {
        address token0 = IZodiacPair(_lpToken).token0();
        address token1 = IZodiacPair(_lpToken).token1();

        require(_tokenToReceive == token0 || _tokenToReceive == token1, "Zap: Token not in LP");

        // Convert to uint256 (from uint112)
        (uint256 reserveA, uint256 reserveB, ) = IZodiacPair(_lpToken).getReserves();

        if (token1 == _tokenToReceive) {
            // sell token0
            uint256 tokenAmountIn = (_lpTokenAmount * reserveA) / IZodiacPair(_lpToken).totalSupply();

            swapAmountIn = _calculateAmountToSwap(tokenAmountIn, reserveA, reserveB);
            swapAmountOut = zodiacRouter.getAmountOut(swapAmountIn, reserveA, reserveB);

            swapTokenOut = token0;
        } else {
            // sell token1
            uint256 tokenAmountIn = (_lpTokenAmount * reserveB) / IZodiacPair(_lpToken).totalSupply();

            swapAmountIn = _calculateAmountToSwap(tokenAmountIn, reserveB, reserveA);
            swapAmountOut = zodiacRouter.getAmountOut(swapAmountIn, reserveB, reserveA);

            swapTokenOut = token1;
        }

        return (swapAmountIn, swapAmountOut, swapTokenOut);
    }

    /*
     * @notice Zap a token in (e.g. token/other token)
     * @param _tokenToZap: token to zap
     * @param _tokenAmountIn: amount of token to swap
     * @param _lpToken: LP token address
     * @param _tokenAmountOutMin: minimum token to receive in the intermediary swap
     */
    function _zapIn(
        address _tokenToZap,
        uint256 _tokenAmountIn,
        address _lpToken,
        uint256 _tokenAmountOutMin
    ) internal returns (uint256 lpTokenReceived) {
        require(_tokenAmountIn >= MINIMUM_AMOUNT, "Zap: Amount too low");

        address token0 = IZodiacPair(_lpToken).token0();
        address token1 = IZodiacPair(_lpToken).token1();

        require(_tokenToZap == token0 || _tokenToZap == token1, "Zap: Wrong tokens");

        // Retrieve the path
        address[] memory path = new address[](2);
        path[0] = _tokenToZap;

        // Initiates an estimation to swap
        uint256 swapAmountIn;

        {
            // Convert to uint256 (from uint112)
            (uint256 reserveA, uint256 reserveB, ) = IZodiacPair(_lpToken).getReserves();

            require((reserveA >= MINIMUM_AMOUNT) && (reserveB >= MINIMUM_AMOUNT), "Zap: Reserves too low");

            if (token0 == _tokenToZap) {
                swapAmountIn = _calculateAmountToSwap(_tokenAmountIn, reserveA, reserveB);
                path[1] = token1;
                require(reserveA / swapAmountIn >= maxZapReverseRatio, "Zap: Quantity higher than limit");
            } else {
                swapAmountIn = _calculateAmountToSwap(_tokenAmountIn, reserveB, reserveA);
                path[1] = token0;
                require(reserveB / swapAmountIn >= maxZapReverseRatio, "Zap: Quantity higher than limit");
            }
        }

        // Approve token to zap if necessary
        _approveTokenIfNeeded(_tokenToZap);

        uint256[] memory swapedAmounts = zodiacRouter.swapExactTokensForTokens(
            swapAmountIn,
            _tokenAmountOutMin,
            path,
            address(this),
            block.timestamp
        );

        // Approve other token if necessary
        if (token0 == _tokenToZap) {
            _approveTokenIfNeeded(token1);
        } else {
            _approveTokenIfNeeded(token0);
        }

        // Add liquidity and retrieve the amount of LP received by the sender
        (, , lpTokenReceived) = zodiacRouter.addLiquidity(
            path[0],
            path[1],
            _tokenAmountIn - swapedAmounts[0],
            swapedAmounts[1],
            1,
            1,
            address(msg.sender),
            block.timestamp
        );

        return lpTokenReceived;
    }

    /*
     * @notice Zap two tokens in, rebalance them to 50-50, before adding them to LP
     * @param _token0ToZap: address of token0 to zap
     * @param _token1ToZap: address of token1 to zap
     * @param _token0AmountIn: amount of token0 to zap
     * @param _token1AmountIn: amount of token1 to zap
     * @param _lpToken: LP token address
     * @param _tokenAmountInMax: maximum token amount to sell (in token to sell in the intermediary swap)
     * @param _tokenAmountOutMin: minimum token to receive in the intermediary swap
     * @param _isToken0Sold: whether token0 is expected to be sold (if false, sell token1)
     */
    function _zapInRebalancing(
        address _token0ToZap,
        address _token1ToZap,
        uint256 _token0AmountIn,
        uint256 _token1AmountIn,
        address _lpToken,
        uint256 _tokenAmountInMax,
        uint256 _tokenAmountOutMin,
        bool _isToken0Sold
    ) internal returns (uint256 lpTokenReceived) {
        require(
            _token0ToZap == IZodiacPair(_lpToken).token0() || _token0ToZap == IZodiacPair(_lpToken).token1(),
            "Zap: Wrong token0"
        );
        require(
            _token1ToZap == IZodiacPair(_lpToken).token0() || _token1ToZap == IZodiacPair(_lpToken).token1(),
            "Zap: Wrong token1"
        );

        require(_token0ToZap != _token1ToZap, "Zap: Same tokens");

        // Initiates an estimation to swap
        uint256 swapAmountIn;

        {
            // Convert to uint256 (from uint112)
            (uint256 reserveA, uint256 reserveB, ) = IZodiacPair(_lpToken).getReserves();

            require((reserveA >= MINIMUM_AMOUNT) && (reserveB >= MINIMUM_AMOUNT), "Zap: Reserves too low");

            if (_token0ToZap == IZodiacPair(_lpToken).token0()) {
                swapAmountIn = _calculateAmountToSwapForRebalancing(
                    _token0AmountIn,
                    _token1AmountIn,
                    reserveA,
                    reserveB,
                    _isToken0Sold
                );
                require(reserveA / swapAmountIn >= maxZapReverseRatio, "Zap: Quantity higher than limit");
            } else {
                swapAmountIn = _calculateAmountToSwapForRebalancing(
                    _token0AmountIn,
                    _token1AmountIn,
                    reserveB,
                    reserveA,
                    _isToken0Sold
                );

                require(reserveB / swapAmountIn >= maxZapReverseRatio, "Zap: Quantity higher than limit");
            }
        }

        require(swapAmountIn <= _tokenAmountInMax, "Zap: Amount to swap too high");

        address[] memory path = new address[](2);

        // Define path for swapping and check whether to approve token to sell in intermediary swap
        if (_isToken0Sold) {
            path[0] = _token0ToZap;
            path[1] = _token1ToZap;
            _approveTokenIfNeeded(_token0ToZap);
        } else {
            path[0] = _token1ToZap;
            path[1] = _token0ToZap;
            _approveTokenIfNeeded(_token1ToZap);
        }

        // Execute the swap and retrieve quantity received
        uint256[] memory swapedAmounts = zodiacRouter.swapExactTokensForTokens(
            swapAmountIn,
            _tokenAmountOutMin,
            path,
            address(this),
            block.timestamp
        );

        // Check whether to approve other token and add liquidity to LP
        if (_isToken0Sold) {
            _approveTokenIfNeeded(_token1ToZap);

            (, , lpTokenReceived) = zodiacRouter.addLiquidity(
                path[0],
                path[1],
                (_token0AmountIn - swapedAmounts[0]),
                (_token1AmountIn + swapedAmounts[1]),
                1,
                1,
                address(msg.sender),
                block.timestamp
            );
        } else {
            _approveTokenIfNeeded(_token0ToZap);
            (, , lpTokenReceived) = zodiacRouter.addLiquidity(
                path[0],
                path[1],
                (_token1AmountIn - swapedAmounts[0]),
                (_token0AmountIn + swapedAmounts[1]),
                1,
                1,
                address(msg.sender),
                block.timestamp
            );
        }

        return lpTokenReceived;
    }

    /*
     * @notice Zap a LP token out to a token (e.g. token/other token)
     * @param _lpToken: LP token address
     * @param _tokenToReceive: token address
     * @param _tokenAmountOutMin: minimum token to receive in the intermediary swap
     */
    function _zapOut(
        address _lpToken,
        address _tokenToReceive,
        uint256 _tokenAmountOutMin
    ) internal returns (uint256) {
        address token0 = IZodiacPair(_lpToken).token0();
        address token1 = IZodiacPair(_lpToken).token1();

        require(_tokenToReceive == token0 || _tokenToReceive == token1, "Zap: Token not in LP");

        // Burn all LP tokens to receive the two tokens to this address
        (uint256 amount0, uint256 amount1) = IZodiacPair(_lpToken).burn(address(this));

        require(amount0 >= MINIMUM_AMOUNT, "ZodiacRouter: INSUFFICIENT_A_AMOUNT");
        require(amount1 >= MINIMUM_AMOUNT, "ZodiacRouter: INSUFFICIENT_B_AMOUNT");

        address[] memory path = new address[](2);
        path[1] = _tokenToReceive;

        uint256 swapAmountIn;

        if (token0 == _tokenToReceive) {
            path[0] = token1;
            swapAmountIn = IERC20(token1).balanceOf(address(this));

            // Approve token to sell if necessary
            _approveTokenIfNeeded(token1);
        } else {
            path[0] = token0;
            swapAmountIn = IERC20(token0).balanceOf(address(this));

            // Approve token to sell if necessary
            _approveTokenIfNeeded(token0);
        }

        // Swap tokens
        zodiacRouter.swapExactTokensForTokens(swapAmountIn, _tokenAmountOutMin, path, address(this), block.timestamp);

        // Return full balance for the token to receive by the sender
        return IERC20(_tokenToReceive).balanceOf(address(this));
    }

    /*
     * @notice Allows to zap a token in (e.g. token/other token)
     * @param _token: token address
     */
    function _approveTokenIfNeeded(address _token) private {
        if (IERC20(_token).allowance(address(this), zodiacRouterAddress) < 1e24) {
            // Re-approve
            IERC20(_token).safeApprove(zodiacRouterAddress, MAX_INT);
        }
    }

    /*
     * @notice Calculate the swap amount to get the price at 50/50 split
     * @param _token0AmountIn: amount of token 0
     * @param _reserve0: amount in reserve for token0
     * @param _reserve1: amount in reserve for token1
     * @return amountToSwap: swapped amount (in token0)
     */
    function _calculateAmountToSwap(
        uint256 _token0AmountIn,
        uint256 _reserve0,
        uint256 _reserve1
    ) private view returns (uint256 amountToSwap) {
        uint256 halfToken0Amount = _token0AmountIn / 2;
        uint256 nominator = zodiacRouter.getAmountOut(halfToken0Amount, _reserve0, _reserve1);
        uint256 denominator = zodiacRouter.quote(
            halfToken0Amount,
            _reserve0 + halfToken0Amount,
            _reserve1 - nominator
        );

        // Adjustment for price impact
        amountToSwap =
            _token0AmountIn -
            Babylonian.sqrt((halfToken0Amount * halfToken0Amount * nominator) / denominator);

        return amountToSwap;
    }

    /*
     * @notice Calculate the amount to swap to get the tokens at a 50/50 split
     * @param _token0AmountIn: amount of token 0
     * @param _token1AmountIn: amount of token 1
     * @param _reserve0: amount in reserve for token0
     * @param _reserve1: amount in reserve for token1
     * @param _isToken0Sold: whether token0 is expected to be sold (if false, sell token1)
     * @return amountToSwap: swapped amount in token0 (if _isToken0Sold is true) or token1 (if _isToken0Sold is false)
     */
    function _calculateAmountToSwapForRebalancing(
        uint256 _token0AmountIn,
        uint256 _token1AmountIn,
        uint256 _reserve0,
        uint256 _reserve1,
        bool _isToken0Sold
    ) private view returns (uint256 amountToSwap) {
        bool sellToken0 = (_token0AmountIn * _reserve1 > _token1AmountIn * _reserve0) ? true : false;

        require(sellToken0 == _isToken0Sold, "Zap: Wrong trade direction");

        if (sellToken0) {
            uint256 token0AmountToSell = (_token0AmountIn - (_token1AmountIn * _reserve0) / _reserve1) / 2;
            uint256 nominator = zodiacRouter.getAmountOut(token0AmountToSell, _reserve0, _reserve1);
            uint256 denominator = zodiacRouter.quote(
                token0AmountToSell,
                _reserve0 + token0AmountToSell,
                _reserve1 - nominator
            );

            // Calculate the amount to sell (in token0)
            token0AmountToSell =
                (_token0AmountIn - (_token1AmountIn * (_reserve0 + token0AmountToSell)) / (_reserve1 - nominator)) /
                2;

            // Adjustment for price impact
            amountToSwap =
                2 *
                token0AmountToSell -
                Babylonian.sqrt((token0AmountToSell * token0AmountToSell * nominator) / denominator);
        } else {
            uint256 token1AmountToSell = (_token1AmountIn - (_token0AmountIn * _reserve1) / _reserve0) / 2;
            uint256 nominator = zodiacRouter.getAmountOut(token1AmountToSell, _reserve1, _reserve0);

            uint256 denominator = zodiacRouter.quote(
                token1AmountToSell,
                _reserve1 + token1AmountToSell,
                _reserve0 - nominator
            );

            // Calculate the amount to sell (in token1)
            token1AmountToSell =
                (_token1AmountIn - ((_token0AmountIn * (_reserve1 + token1AmountToSell)) / (_reserve0 - nominator))) /
                2;

            // Adjustment for price impact
            amountToSwap =
                2 *
                token1AmountToSell -
                Babylonian.sqrt((token1AmountToSell * token1AmountToSell * nominator) / denominator);
        }

        return amountToSwap;
    }
}