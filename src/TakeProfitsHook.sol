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

    mapping(PoolId poolId => int24 lastTick) public lastTicks;

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
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4, int128) {
        // NOTE: Don't allow recurring calls and reentrancy
        if (sender == address(this)) return (this.afterSwap.selector, 0);
        // NOTE: Fulfill orders
        // 1. calculate tick shift range
        // 2. find out first order within tick shift range that we can fill
        // 3. fill order
        // 4. go back to step 1

        bool tryMore = true; // Try to fill more orders or not
        int24 currentTick;

        while (tryMore) {
            // While we know we should try to fill another order, we need to...
            // We will try a function, `tryExecutingOrder`
            // Returns a new value for tryMore and returns a new value for currentTick
            // Core idea is `tryExecutingOrder` will try to find the first order we can fill
            // we cause a price shift if we will it, tryMore = true, get new current shift
            // if we dont have orders to fill, then we return tryMore = false, with currentTick

            // If bob id a zeroForOne swap, we need orders in the opposite direction (oneForZero)
            // If bob did a oneForZero swap, we need orders in the opposite direction (zeroForOne)
            (tryMore, currentTick) = tryExecutingOrder(
                key,
                // The direction of orders to look for
                !params.zeroForOne
            );
        }
        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    function tryExecutingOrder(
        PoolKey calldata key,
        bool executeZeroForOne
    ) internal returns (bool tryMore, int24 newTick) {
        // CoW:
        // if alice wants to sell 1 eth at 3600, current price maybe 3500
        // bob places swap to buy 1 eth and slippge requirements are designed such that
        // he's willing to pay up to 3600
        // in before swap you can just trade alice and bob's orders
        // But:
        // we will get current tick from pool
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        // NOTE: We pass in pool id
        int24 lastTick = lastTicks[key.toId()];

        if (currentTick > lastTick) {
            // loop over all tick values, from last tick to current tick
            // try to find and entry in our pending orders mapping
            // where input amount > 0 (i.e. we haev something we need to swap)

            // SIDENOTE: this is why it helps a lot to place orders on known tick values
            // "valid" / "usable" ticks

            for (
                int24 tick = lastTick;
                tick <= currentTick;
                tick += key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][
                    executeZeroForOne
                ];

                if (inputAmount > 0) {
                    // we have an order to fill
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        } else {
            for (
                int24 tick = lastTick;
                tick > currentTick;
                tick -= key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][
                    executeZeroForOne
                ];

                if (inputAmount > 0) {
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }

        return (false, currentTick);
    }

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
