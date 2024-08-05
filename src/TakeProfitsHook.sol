// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/**
  1. Placing orders
  We need:
  - pool she's placing order, poolKey
  - which token to sell (eth or usdc)
  - what tick she wants to sell at 
  - how many toens she wants to sell

  -- 
  ticks are integers that are at various values separated by some tick spacing
 */

// NOTE: This could've been ERC-6909, but we're using ERC-1155 for simplicity
contract TakeProfitsHook is BaseHook, ERC1155 {
    // StateLibrary is new here and we haven't seen that before
    // It's used to add helper functions to the PoolManager to read
    // storage values.
    // In this case, we use it for accessing `currentTick` values
    // from the pool manager
    using StateLibrary for IPoolManager;

    // PoolIdLibrary used to convert PoolKeys to IDs
    using PoolIdLibrary for PoolKey;
    // Used to represent Currency types and helper functions like `.isNative()`
    using CurrencyLibrary for Currency;
    // Used for helpful math operations like `mulDiv`
    using FixedPointMathLib for uint256;

    // We don't store information about who place the order
    // this is intent ional, we will mint them our own token to represent an open position / order

    // it is possible for multiple people to want to place the same order
    // alice wants to sell 5 eth at 3500 usdc each
    // bob wants to do 10 eth at the same price

    // we will combine bob and alice order into single order, do it as a single swap

    // Pool => tick to sell => direction of swap => amount of tokens to sell
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount)))
        public pendingOrders;

    // Is for each order that exists, how many erc1155 tokens have been minted out
    // equal to total amount of input amount tokens that exist at that order
    mapping(uint256 orderIds => uint256 tokenSupply) public claimTokensSupply;

    mapping(uint256 orderId => uint256 outputClaimable)
        public claimableOutputTokens;

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    // Constructor
    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}

    // BaseHook Functions
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4) {
        // TODO
        return this.afterInitialize.selector;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4, int128) {
        // TODO
        return (this.afterSwap.selector, 0);
    }

    // Write the redeem function
    // Write the executeOrder function
    // Write the swapAndSettleBalances function

    function getLowerUsableTick(
        int24 tick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        // what happens if tick is negative
        // alice provides tick = -75
        if (tick < 0 && tick % tickSpacing != 0) {
            intervals--;
        }

        return intervals * tickSpacing;
    }

    function getOrderId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(keccak256(abi.encodePacked(key.toId(), tick, zeroForOne)));
    }

    function placeOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) external returns (int24) {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        claimTokensSupply[orderId] += inputAmount;
        _mint(msg.sender, orderId, inputAmount, "");

        address sellToken = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        return tick;
    }

    // TODO: Handle partial cancellation (add another field, compare and burn partially)
    function cancelOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne
    ) external {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        uint256 orderTokens = balanceOf(msg.sender, orderId);
        if (orderTokens == 0) {
            revert InvalidOrder();
        }
        pendingOrders[key.toId()][tick][zeroForOne] -= orderTokens;
        claimTokensSupply[orderId] -= orderTokens;
        _burn(msg.sender, orderId, orderTokens);

        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, orderTokens);
    }

    function redeem(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmountToClaimFor
    ) external {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);

        if (claimTokensSupply[orderId] == 0) {
            revert NothingToClaim();
        }

        uint256 orderTokens = balanceOf(msg.sender, orderId);
        if (orderTokens < inputAmountToClaimFor) {
            revert NotEnoughToClaim();
        }

        uint256 totalClaimableForOrder = claimableOutputTokens[orderId];
        uint256 totalInputAmountForPosition = claimTokensSupply[orderId];

        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            totalClaimableForOrder,
            totalInputAmountForPosition
        );

        claimableOutputTokens[orderId] -= outputAmount;
        claimTokensSupply[orderId] -= inputAmountToClaimFor;
        _burn(msg.sender, orderId, inputAmountToClaimFor);

        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    function swapAndSettleBalances(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
        BalanceDelta delta = poolManager.swap(key, params, "");

        if (params.zeroForOne) {
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
    }

    function executeOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount
    ) internal {
        BalanceDelta delta = swapAndSettleBalances(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // NOTE: Negative value provided to signify an "exact input for output" swap
                amountSpecified: -int256(inputAmount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        claimableOutputTokens[orderId] += outputAmount;
    }

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }
}
