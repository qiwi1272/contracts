// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
}

interface IV2SwapRouter02 {
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IUniswapV4Router04 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        PoolKey memory poolKey,
        bytes memory hookData,
        address reciever,
        uint256 deadline
    ) external returns (BalanceDelta);
}

interface IUniV3Pool {
    function fee() external view returns (uint24);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface ICurvePool {
    function A() external view returns (uint256);
    function fee() external view returns (uint256);
    function coins(uint256 arg0) external view returns (address);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 _dx, uint256 _min_dy) external returns (uint256);
}

interface FERC20 is IERC20 {
    function decimals() external view returns (uint8);
}

// this was used to blindly generate calldata on an l2 or local fork 
// i.e. without verifying contract addresses.

contract Router {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    IV2SwapRouter02 internal constant _v3router = IV2SwapRouter02(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    IUniswapV4Router04 internal constant _v4router = IUniswapV4Router04(0x00000000000044a361Ae3cAc094c9D1b14Eece97);
    IPoolManager internal constant _poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    uint160 internal constant MIN_SQRT_RATIO = uint160(4295128741);
    uint160 internal constant MAX_SQRT_RATIO = uint160(1461446703485210103287273052203988822378723970340);

    function getSwap(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes32 poolOrKey,
        PoolKey memory key
    ) external view returns (address callee, bytes memory data, address tokenOut) {
        address maybePool = address(uint160(uint256(poolOrKey)));

        if (!isPool(poolOrKey)) {
            // v4
            (callee, data, tokenOut) = _getSwapV4(tokenIn, amountIn, minAmountOut, recipient, key);
        } else if (isCurvePool(maybePool)) {
            // curve
            (callee, data, tokenOut) = _getSwapCurve(tokenIn, maybePool, amountIn, minAmountOut);
        } else {
            // v3
            (callee, data, tokenOut) = _getSwapV3(tokenIn, maybePool, amountIn, minAmountOut, recipient);
        }
    }

    function _getSwapCurve(address tokenInput, address pool, uint256 amountIn, uint256 minAmountOut)
        internal
        view
        returns (address callee, bytes memory data, address tokenOut)
    {
        ICurvePool curvePool = ICurvePool(pool);

        address token0 = curvePool.coins(0);
        address token1 = curvePool.coins(1);

        bool zeroForOne = tokenInput == token0;

        int128 first = zeroForOne ? int128(0) : int128(1);
        int128 second = zeroForOne ? int128(1) : int128(0);
        tokenOut = zeroForOne ? token1 : token0;

        callee = pool;
        data = abi.encodeWithSelector(ICurvePool.exchange.selector, first, second, amountIn, minAmountOut);
    }

    function _getSwapV3(address tokenInput, address pool, uint256 amountIn, uint256 minAmountOut, address to)
        internal
        view
        returns (address callee, bytes memory data, address tokenOut)
    {
        IUniV3Pool v3Pool = IUniV3Pool(pool);

        // Construct the swap parameters
        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();

        bool zeroForOne = tokenInput == token0;

        address tokenIn = zeroForOne ? token0 : token1;
        tokenOut = zeroForOne ? token1 : token0;

        uint24 poolFee = v3Pool.fee();

        callee = address(_v3router);
        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: poolFee,
            recipient: to,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO : MAX_SQRT_RATIO
        });
        data = abi.encodeWithSelector(_v3router.exactInputSingle.selector, params);
    }

    function _getSwapV4(address tokenInput, uint256 amountIn, uint256 minAmountOut, address to, PoolKey memory key)
        internal
        view
        returns (address callee, bytes memory data, address tokenOut)
    {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        bool zeroForOne = tokenInput == token0;
        tokenOut = zeroForOne ? token1 : token0;

        callee = address(_v4router);
        data = abi.encodeWithSelector(
            _v4router.swapExactTokensForTokens.selector,
            amountIn,
            minAmountOut,
            zeroForOne,
            key,
            new bytes(0),
            to,
            block.timestamp + 60
        );
    }

    function getQuote(bytes32 poolOrKey) external view returns (uint256 price, uint256 fee) {
        address maybePool = address(uint160(uint256(poolOrKey)));

        if (!isPool(poolOrKey)) {
            // v4
            (uint256 rawPrice, uint24 rawFee) = _getQuoteV4(poolOrKey);
            price = rawPrice;
            fee = uint256(rawFee);
        } else if (isCurvePool(maybePool)) {
            // curve
            uint256 oneToken = uint256(10) ** FERC20(ICurvePool(maybePool).coins(uint256(0))).decimals();
            (price, fee) = _getQuoteCurve(maybePool, oneToken);
        } else {
            // v3
            (uint256 rawPrice, uint24 rawFee) = _getQuoteV3(maybePool);
            price = rawPrice;
            fee = uint256(rawFee);
        }
    }

    function _getQuoteCurve(address pool, uint256 amountIn) internal view returns (uint256 price, uint256 fee) {
        price = ICurvePool(pool).get_dy(int128(0), int128(1), amountIn);
        fee = ICurvePool(pool).fee();
    }

    function _getQuoteV3(address pool) internal view returns (uint256 price, uint24 fee) {
        (uint160 sqrtPriceX96,,,,,,) = IUniV3Pool(pool).slot0();
        fee = IUniV3Pool(pool).fee();

        price = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 192);
    }

    function _getQuoteV4(bytes32 keyId) internal view returns (uint256 price, uint24 fee) {
        (uint160 sqrtPriceX96,,, uint24 rawFee) = _poolManager.getSlot0(PoolId.wrap(keyId));
        price = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 192);
        fee = rawFee;
    }

    function getLiquidity(bytes32 poolOrKey) public view returns (uint128 liquidity) {
        if (!isPool(poolOrKey)) {
            // v4
            liquidity = _poolManager.getLiquidity(PoolId.wrap(poolOrKey));
        } else {
            // v3
            address maybePool = address(uint160(uint256(poolOrKey)));
            liquidity = IUniV3Pool(maybePool).liquidity();
        }
    }

    function isPool(bytes32 input) public view returns (bool) {
        address maybeAddress = address(uint160(uint256(input)));
        uint256 size;
        assembly {
            size := extcodesize(maybeAddress)
        }
        return size > 0;
    }

    function isCurvePool(address pool) public view returns (bool) {
        try ICurvePool(pool).A() {
            return true;
        } catch {
            return false;
        }
    }
}
