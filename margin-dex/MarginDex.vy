# @version 0.3.10

###################################################################
#
# @title Unstoppable Margin DEX - Trading Logic
# @license GNU AGPLv3
# @author unstoppable.ooo
#
# @custom:security-contact team@unstoppable.ooo
#
# @notice
#    This contract is part of the Unstoppable Margin DEX.
#
#    It is the main contract traders interact with in order
#    to create leveraged 1:1 backed spot trades.
#    
#    It allows users to open trades, manage their trades and 
#    use advanced features like Limit Orders, Stop Loss & Take
#    Profit orders.
#
###################################################################

from vyper.interfaces import ERC20

PRECISION: constant(uint256) = 10**18
PERCENTAGE_BASE: constant(uint256) = 10000 # == 100%

# VAULT
struct Position:
    uid: bytes32
    account: address
    margin_token: address
    margin_amount: uint256
    debt_token: address
    debt_shares: uint256
    position_token: address
    position_amount: uint256

interface Vault:
    def open_position(
        _caller: address,
        _account: address,
        _position_token: address,
        _position_amount: uint256,
        _debt_token: address,
        _debt_amount: uint256,
        _margin_token: address,
        _margin_amount: uint256,
        _data: Bytes[1024],
    ) -> bytes32: nonpayable
    def change_position(
        _caller: address,
        _position_uid: bytes32,
        _debt_change: int256,                 # in debt_token
        _margin_change: int256,               # in margin_token
        _position_change: int256,             # in position_token
        _realized_pnl: int256,                # in margin_token
        _data: Bytes[1024],                    # callback data
        _allow_higher_price_impact: bool = False,
    ): nonpayable
    def to_usd_oracle_price(_token: address) -> uint256: view
    def is_enabled_market(_token1: address, _token2: address) -> bool: view
    def debt(_position_uid: bytes32) -> uint256: view
    def positions(_position_uid: bytes32) -> Position: view
    def effective_leverage(_position_uid: bytes32, _decimals: uint256 = 0) -> uint256: view
    def is_liquidatable(_position_uid: bytes32) -> bool: view
    def swap_margin(
        _caller: address,
        _account: address,
        _token0: address,
        _token1: address,
        _amount0: uint256,
        _amount1: uint256,
        _data: Bytes[1024]
    ): nonpayable

interface SwapRouter:
    def swap(
        _token_in: address,
        _token_out: address,
        _amount_in: uint256,
        _min_amount_out: uint256
    ) -> uint256: nonpayable
    def swap_exact_out(
        _token_in: address,
        _token_out: address,
        _amount_out: uint256,
        _max_amount_in: uint256,
    ) -> uint256: nonpayable

vault: public(address)

swap_router: public(address)

#################
#    TRADING
#################
struct TakeProfitOrder:
    trigger_price: uint256
    reduce_by_amount: uint256
    executed: bool

struct StopLossOrder:
    trigger_price: uint256
    reduce_by_amount: uint256
    executed: bool

struct Trade:
    uid: bytes32
    account: address
    tp_orders: DynArray[TakeProfitOrder, 8]
    sl_orders: DynArray[StopLossOrder, 8]

struct LimitOrder:
    uid: bytes32
    account: address
    position_token: address
    min_position_amount_out: uint256
    debt_token: address
    debt_amount: uint256
    margin_token: address
    margin_amount: uint256
    valid_until: uint256
    tp_orders: DynArray[TakeProfitOrder, 8]
    sl_orders: DynArray[StopLossOrder, 8]


# uid -> LimitOrder
limit_orders: public(HashMap[bytes32, LimitOrder])
# account -> LimitOrder
limit_order_uids: public(HashMap[address, DynArray[bytes32, 1024]])

uid_nonce: uint256
# account -> Trade.uid
trades_by_account: public(HashMap[address, DynArray[bytes32, 1024]])
# uid -> Trade
open_trades: public(HashMap[bytes32, Trade])

# owner -> delegate accounts
is_delegate: public(HashMap[address, HashMap[address, bool]])

is_whitelisted_caller: public(HashMap[address, bool])

admin: public(address)
suggested_admin: public(address)

is_accepting_new_orders: public(bool)

leverage_buffer: public(uint256)


@external
def __init__(_vault: address):
    self.admin = msg.sender
    assert _vault != empty(address), "Vault must be configured"
    self.vault = _vault
    self.is_whitelisted_caller[self] = True

#####################################
#
#              TRADING
#
#####################################

event TradeOpened:
    account: indexed(address)
    uid: bytes32
    trade: Trade

@nonreentrant("lock")
@external
def open_trade(
    _account: address,
    _position_token: address,
    _min_position_amount_out: uint256,
    _debt_token: address,
    _debt_amount: uint256,
    _margin_token: address,
    _margin_amount: uint256,
    _tp_orders: DynArray[TakeProfitOrder, 8],
    _sl_orders: DynArray[StopLossOrder, 8],
):
    assert (_account == msg.sender) or self.is_delegate[_account][msg.sender], "unauthorized"


    self._open_trade(
        _account,
        _position_token,
        _min_position_amount_out,
        _debt_token,
        _debt_amount,
        _margin_token,
        _margin_amount,
        _tp_orders,
        _sl_orders,
    )

@internal
def _open_trade(
    _account: address,
    _position_token: address,
    _min_position_amount_out: uint256,
    _debt_token: address,
    _debt_amount: uint256,
    _margin_token: address,
    _margin_amount: uint256,
    _tp_orders: DynArray[TakeProfitOrder, 8],
    _sl_orders: DynArray[StopLossOrder, 8],
):
    """
    @notice
        Creates a new Trade for user by opening a
        leveraged spot position in the Vault.

        Requires the user to have a positive margin
        balance in the Vault.
        Requires liquidity to be available in the Vault.

        All trades and their underlying positions are
        fully isolated.
    """

    swap_sequence: uint256[5][3] = [[0, 2, 0, _debt_amount, _min_position_amount_out], [0, 0, 0, 0, 0], [0, 0, 0, 0, 0]]  # [[amount_in, amount_out, exact_in / exact_out]]
    position_uid: bytes32 = Vault(self.vault).open_position(
        self,
        _account,
        _position_token,
        _min_position_amount_out,
        _debt_token,
        _debt_amount,
        _margin_token,
        _margin_amount,
        _abi_encode(swap_sequence),
    )

    trade: Trade = Trade(
        {
            uid: position_uid,
            account: _account,
            tp_orders: _tp_orders,
            sl_orders: _sl_orders,
        }
    )

    self.open_trades[position_uid] = trade
    self.trades_by_account[_account].append(position_uid)

    log TradeOpened(_account, position_uid, trade)


event TradeChanged:
    account: indexed(address)
    uid: bytes32

event TradeClosed:
    account: indexed(address)
    uid: bytes32

@nonreentrant("lock")
@external
def change_trade(
    _caller: address,
    _uid: bytes32,
    _debt_change: int256,                 # in debt_token
    _margin_change: int256,               # in margin_token
    _position_change: int256,             # in position_token
    _realized_pnl: int256,                # in margin_token
    _data: Bytes[1024]                    # callback data
):
    self._change_trade(_caller, _uid, _debt_change, _margin_change, _position_change, _realized_pnl, _data)


@internal
def _change_trade(
    _caller: address,
    _uid: bytes32,
    _debt_change: int256,                 # in debt_token
    _margin_change: int256,               # in margin_token
    _position_change: int256,             # in position_token
    _realized_pnl: int256,                # in margin_token
    _data: Bytes[1024]                    # callback data
):
    assert (self.open_trades[_uid].account == msg.sender) or self.is_delegate[self.open_trades[_uid].account][msg.sender] or self._is_liquidatable(_uid), "unauthorized"

    assert self.is_whitelisted_caller[_caller], "invalid caller"

    if self._is_liquidatable(_uid):
        assert (_debt_change > 0) and (_realized_pnl == 0), "invalid inputs"

    Vault(self.vault).change_position(
        _caller,
        _uid,
        _debt_change,
        _margin_change,
        _position_change,
        _realized_pnl,
        _data,
        (self.open_trades[_uid].account == msg.sender or self.is_delegate[self.open_trades[_uid].account][msg.sender]), # allow higher price impact if trader himself executes
    )

    if Vault(self.vault).positions(_uid).position_amount == 0:
        # position was fully closed
        self._cleanup_trade(_uid)
        log TradeClosed(self.open_trades[_uid].account, _uid)
        return

    log TradeChanged(self.open_trades[_uid].account, _uid)


@nonreentrant("lock")
@external
def close_trade(_caller: address, _uid: bytes32, _margin_amount: int256):
    debt_amount: uint256 = Vault(self.vault).debt(_uid)
    position_amount: uint256 = Vault(self.vault).positions(_uid).position_amount

    # in profit
    swap_sequence: uint256[5][3] = [
        [2, 0, 1, position_amount, debt_amount], # position -> debt, exact_out
        [2, 1, 0, position_amount, 0],           # position -> margin, exact_in (position_amount is capped to remaining in callback) 
        [0, 0, 0, 0, 0]
    ] 

    # in loss
    if _margin_amount < 0:
        swap_sequence = [
            [2, 0, 0, position_amount, 0], # position -> debt, exact_in
            [1, 0, 2, convert(abs(_margin_amount), uint256), debt_amount],  # margin -> debt, exact total debt
            [0, 0, 0, 0, 0]
        ] 

    self._change_trade(
        _caller,
        _uid,
        convert(debt_amount, int256),
        _margin_amount,
        convert(position_amount, int256) * -1,
        0,
        _abi_encode(swap_sequence),
    )



@internal
def _cleanup_trade(_trade_uid: bytes32):
    account: address = self.open_trades[_trade_uid].account
    self.open_trades[_trade_uid] = empty(Trade)
    uids: DynArray[bytes32, 1024] = self.trades_by_account[account]
    for i in range(1024):
        if uids[i] == _trade_uid:
            uids[i] = uids[len(uids) - 1]
            uids.pop()
            break
        if i == len(uids) - 1:
            raise
    self.trades_by_account[account] = uids


@view
@external
def get_all_open_trades(_account: address) -> DynArray[Trade, 1024]:
    uids: DynArray[bytes32, 1024] = self.trades_by_account[_account]
    trades: DynArray[Trade, 1024] = empty(DynArray[Trade, 1024])

    for uid in uids:
        trades.append(self.open_trades[uid])

    return trades

@view
@external
def get_all_open_limit_orders(_account: address) -> DynArray[LimitOrder, 1024]:
    uids: DynArray[bytes32, 1024] = self.limit_order_uids[_account]
    limit_orders: DynArray[LimitOrder, 1024] = empty(DynArray[LimitOrder, 1024])

    for uid in uids:
        limit_orders.append(self.limit_orders[uid])

    return limit_orders

@nonreentrant("lock")
@external
def swap_margin(
    _account: address,
    _token_in: address,
    _token_out: address,
    _amount_in: uint256,
    _min_amount_out: uint256,
):
    """
    @notice
        Allows a user to easily swap between his margin balances.
    """
    assert (_account == msg.sender) or self.is_delegate[_account][msg.sender], "unauthorized"

    # def swap_margin(
    #     _caller: address,
    #     _account: address,
    #     _token0: address,
    #     _token1: address,
    #     _amount0: uint256,
    #     _amount1: uint256,
    #     _data: Bytes[1024]
    # ):
    swap_sequence: uint256[5][3] = [[0, 1, 0, _amount_in, _min_amount_out], [0, 0, 0, 0, 0], [0, 0, 0, 0, 0]]  # [[amount_in, amount_out, exact_in / exact_out, amount_in, amount_out]]
    Vault(self.vault).swap_margin(
        self,
        _account,
        _token_in,
        _token_out,
        _amount_in,
        _min_amount_out,
        _abi_encode(swap_sequence),
    )


#####################################
#
#    CONDITIONAL ORDERS - TP/SL
#
#####################################

event TpSlUpdated:
    trade_uid: bytes32
    trade: Trade

@external
def update_tp_sl_orders(
    _trade_uid: bytes32, 
    _tp_orders: DynArray[TakeProfitOrder, 8],
    _sl_orders: DynArray[StopLossOrder, 8]
    ):
    trade: Trade = self.open_trades[_trade_uid]
    assert (trade.account == msg.sender) or self.is_delegate[trade.account][msg.sender], "unauthorized"
    assert self.is_accepting_new_orders, "paused"

    trade.tp_orders = _tp_orders
    trade.sl_orders = _sl_orders

    self.open_trades[_trade_uid] = trade    
    log TpSlUpdated(_trade_uid, trade)


event TpExecuted:
    trade_uid: bytes32
    index: uint8

@nonreentrant("lock")
@external
def execute_tp_order(_trade_uid: bytes32, _tp_order_index: uint8, _caller: address, _debt_change: int256, _margin_change: int256, _realized_pnl: int256, _data: Bytes[1024]):
    """
    @notice
        Allows a TakeProfit order to be executed.
        Any msg.sender may execute conditional orders for all accounts.
        The specified trigger_price and Chainlink based current_exchange_rate 
        ensures orders are only executed when intended.
    """
    assert _debt_change >= 0, "no new debt during tp/sl"
    assert _realized_pnl <= 0, "cannot add more margin during tp/sl"
    assert self.is_whitelisted_caller[_caller], "invalid caller"

    leverage_before: uint256 = self._effective_leverage(_trade_uid, 2)

    tp_order: TakeProfitOrder = self.open_trades[_trade_uid].tp_orders[_tp_order_index]
    assert tp_order.reduce_by_amount > 0, "invalid amount"

    position: Position = Vault(self.vault).positions(_trade_uid)

    current_exchange_rate: uint256 = self._current_exchange_rate(position.position_token, position.debt_token)
    assert tp_order.trigger_price <= current_exchange_rate, "trigger price not reached"
    assert tp_order.executed == False, "order already executed"

    tp_order.executed = True
    self.open_trades[_trade_uid].tp_orders[_tp_order_index] = tp_order

    reduce_amount: uint256 = min(tp_order.reduce_by_amount, position.position_amount)
    is_full_close: bool = reduce_amount == position.position_amount
    Vault(self.vault).change_position(
        _caller,
        _trade_uid,
        _debt_change,
        _margin_change,
        -1 * convert(reduce_amount, int256),
        _realized_pnl,
        _data,
    )

    if Vault(self.vault).positions(_trade_uid).position_amount > 0:
        # partial close
        assert not is_full_close, "was supposed to be full close"
        assert Vault(self.vault).positions(_trade_uid).margin_amount <= position.margin_amount, "cannot increase margin on partial tp"
        
        # enforce consistent leverage
        leverage_after: uint256 = self._effective_leverage(_trade_uid, 2)
        assert (leverage_after >= leverage_before - min(leverage_before, self.leverage_buffer)) and (leverage_after <= leverage_before + self.leverage_buffer), "invalid tp execution (leverage)"
    else:
        # position was fully closed
        self._cleanup_trade(_trade_uid)
        log TradeClosed(self.open_trades[_trade_uid].account, _trade_uid)

    log TpExecuted(_trade_uid, _tp_order_index)


event SlExecuted:
    trade_uid: bytes32
    index: uint8

@nonreentrant("lock")
@external
def execute_sl_order(_trade_uid: bytes32, _sl_order_index: uint8, _caller: address, _debt_change: int256, _margin_change: int256, _realized_pnl: int256, _data: Bytes[1024]):
    """
    @notice
        Allows a StopLoss order to be executed.
        Any msg.sender may execute conditional orders for all accounts.
        The specified trigger_price and Chainlink based current_exchange_rate 
        ensures orders are only executed when intended.
    """
    assert _debt_change >= 0, "no new debt during tp/sl"
    assert _realized_pnl <= 0, "cannot add more margin during tp/sl"
    assert self.is_whitelisted_caller[_caller], "invalid caller"

    leverage_before: uint256 = self._effective_leverage(_trade_uid, 2)

    sl_order: StopLossOrder = self.open_trades[_trade_uid].sl_orders[_sl_order_index]
    assert sl_order.reduce_by_amount > 0, "invalid amount"

    position: Position = Vault(self.vault).positions(_trade_uid)

    current_exchange_rate: uint256 = self._current_exchange_rate(position.position_token, position.debt_token)
    assert sl_order.trigger_price >= current_exchange_rate, "trigger price not reached"
    assert sl_order.executed == False, "order already executed"

    sl_order.executed = True
    self.open_trades[_trade_uid].sl_orders[_sl_order_index] = sl_order

    reduce_amount: uint256 = min(sl_order.reduce_by_amount, position.position_amount)
    is_full_close: bool = reduce_amount == position.position_amount
    Vault(self.vault).change_position(
        _caller,
        _trade_uid,
        _debt_change,
        _margin_change,
        -1 * convert(reduce_amount, int256),
        _realized_pnl,
        _data,
    )

    if Vault(self.vault).positions(_trade_uid).position_amount > 0:
        # partial close
        assert not is_full_close, "was supposed to be full close"
        assert Vault(self.vault).positions(_trade_uid).margin_amount <= position.margin_amount, "cannot increase margin on partial sl"

        # enforce consistent leverage
        leverage_after: uint256 = self._effective_leverage(_trade_uid, 2)
        assert (leverage_after >= leverage_before - min(leverage_before, self.leverage_buffer)) and (leverage_after <= leverage_before + self.leverage_buffer), "invalid sl execution (leverage)"
    else:
        # position was fully closed
        self._cleanup_trade(_trade_uid)
        log TradeClosed(self.open_trades[_trade_uid].account, _trade_uid)

    log SlExecuted(_trade_uid, _sl_order_index)


event TpRemoved:
    trade: Trade


@external
def cancel_tp_order(_trade_uid: bytes32, _tp_order_index: uint8):
    """
    @notice
        Removes a pending TakeProfit order.
    """
    assert (self.open_trades[_trade_uid].account == msg.sender) or self.is_delegate[self.open_trades[_trade_uid].account][msg.sender], "unauthorized"
    assert _tp_order_index < convert(len(self.open_trades[_trade_uid].tp_orders), uint8), "invalid index"

    if len(self.open_trades[_trade_uid].tp_orders) > 1:
        self.open_trades[_trade_uid].tp_orders[_tp_order_index] = self.open_trades[_trade_uid].tp_orders[len(self.open_trades[_trade_uid].tp_orders) - 1]

    self.open_trades[_trade_uid].tp_orders.pop()

    log TpRemoved(self.open_trades[_trade_uid])


event SlRemoved:
    trade: Trade


@external
def cancel_sl_order(_trade_uid: bytes32, _sl_order_index: uint8):
    """
    @notice
        Removes a pending StopLoss order.
    """
    assert (self.open_trades[_trade_uid].account == msg.sender) or self.is_delegate[self.open_trades[_trade_uid].account][msg.sender], "unauthorized"
    assert _sl_order_index < convert(len(self.open_trades[_trade_uid].sl_orders), uint8), "invalid index"

    if len(self.open_trades[_trade_uid].sl_orders) > 1:
        self.open_trades[_trade_uid].sl_orders[_sl_order_index] = self.open_trades[_trade_uid].sl_orders[len(self.open_trades[_trade_uid].sl_orders) - 1]

    self.open_trades[_trade_uid].sl_orders.pop()

    log SlRemoved(self.open_trades[_trade_uid])


#####################################
#
#           LIMIT ORDERS
#
#####################################


event LimitOrderPosted:
    uid: bytes32
    account: indexed(address)
    token_in: indexed(address)
    token_out: indexed(address)
    amount_in: uint256
    min_amount_out: uint256
    valid_until: uint256


@external
def post_limit_order(
    _account: address,
    _position_token: address,
    _debt_token: address,
    _margin_token: address,
    _margin_amount: uint256,
    _debt_amount: uint256,
    _min_amount_out: uint256,
    _valid_until: uint256,
    _tp_orders: DynArray[TakeProfitOrder, 8],
    _sl_orders: DynArray[StopLossOrder, 8],
) -> LimitOrder:
    """
    @notice
        Allows users to post a LimitOrder that can open a Trade
        under specified conditions.
    """
    assert self.is_accepting_new_orders, "not accepting new orders"
    assert (_account == msg.sender) or self.is_delegate[_account][msg.sender], "unauthorized"

    assert Vault(self.vault).is_enabled_market(_debt_token, _position_token), "market not enabled"
    assert _margin_amount > 0, "invalid margin amount"

    uid: bytes32 = self._generate_uid()

    limit_order: LimitOrder = LimitOrder(
        {
            uid: uid,
            account: _account,
            position_token: _position_token,
            min_position_amount_out: _min_amount_out,
            debt_token: _debt_token,
            debt_amount: _debt_amount,
            margin_token: _margin_token,
            margin_amount: _margin_amount,
            valid_until: _valid_until,
            tp_orders: _tp_orders,
            sl_orders: _sl_orders,
        }
    )

    self.limit_orders[uid] = limit_order
    self.limit_order_uids[_account].append(uid)

    amount_in: uint256 = _margin_amount + _debt_amount
    log LimitOrderPosted(uid, _account, _debt_token, _position_token, amount_in, _min_amount_out, _valid_until)

    return limit_order


event LimitOrderExecuted:
    account: indexed(address)
    limit_order_uid: bytes32


@nonreentrant("lock")
@external
def execute_limit_order(_uid: bytes32):
    """
    @notice
        Allows executing a pending LimitOrder.
        Any msg.sender may execute LimitOrders for all accounts.
        The specified min_amount_out ensures the Trade is only
        opened at the intended exchange rate / price.
    """
    assert self.is_accepting_new_orders, "not accepting new orders"
 
    limit_order: LimitOrder = self.limit_orders[_uid]
    assert limit_order.valid_until >= block.timestamp, "expired"

    self._open_trade(
        limit_order.account,
        limit_order.position_token,
        limit_order.min_position_amount_out,
        limit_order.debt_token,
        limit_order.debt_amount,
        limit_order.margin_token,
        limit_order.margin_amount,
        limit_order.tp_orders,
        limit_order.sl_orders
    )

    log LimitOrderExecuted(limit_order.account, _uid)

    self._remove_limit_order(_uid)



event LimitOrderCancelled:
    account: indexed(address)
    uid: bytes32


@external
def cancel_limit_order(_uid: bytes32):
    """
    @notice
        Removes a pending LimitOrder.
    """
    assert (self.limit_orders[_uid].account == msg.sender) or self.is_delegate[self.limit_orders[_uid].account][msg.sender], "unauthorized"

    log LimitOrderCancelled(self.limit_orders[_uid].account, _uid)

    self._remove_limit_order(_uid)



@internal
def _remove_limit_order(_uid: bytes32):
    order: LimitOrder = self.limit_orders[_uid]
    self.limit_orders[_uid] = empty(LimitOrder)

    uids: DynArray[bytes32, 1024] = self.limit_order_uids[order.account]
    for i in range(1024):
        if uids[i] == _uid:
            uids[i] = uids[len(uids) - 1]
            uids.pop()
            break
        if i == len(uids) - 1:
            raise
    self.limit_order_uids[order.account] = uids


#####################################
#
#           LIQUIDATIONS
#
#####################################

@view
@external
def is_liquidatable(_trade_uid: bytes32) -> bool:
    """
    @notice
        Trades are leveraged and based on an undercollateralized
        loan in the Vault Position.
        If the Trades effective leverage exceeds the maximum allowed
        leverage for that market, the Trade and its underlying Vault
        Position become liquidatable.
    """
    return self._is_liquidatable(_trade_uid)

@view
@internal
def _is_liquidatable(_trade_uid: bytes32) -> bool:
    return Vault(self.vault).is_liquidatable(_trade_uid)


#####################################
#
#     LEVERAGE & TRADE HEALTH
#
#####################################

@view
@external
def effective_leverage(_trade_uid: bytes32, _decimals: uint256 = 0) -> uint256:
    return self._effective_leverage(_trade_uid, _decimals)

@view
@internal
def _effective_leverage(_trade_uid: bytes32, _decimals: uint256 = 0) -> uint256:
    return Vault(self.vault).effective_leverage(self.open_trades[_trade_uid].uid, _decimals)


@view
@external
def current_exchange_rate(_token0: address, _token1: address) -> uint256:
    return self._current_exchange_rate(_token0, _token1)

@view
@internal
def _current_exchange_rate(_token0: address, _token1: address) -> uint256:
    # returns exchange rate with PRECISION decimals
    return (
        Vault(self.vault).to_usd_oracle_price(_token0)
        * PRECISION
        / Vault(self.vault).to_usd_oracle_price(_token1)
    )


#####################################
#
#    ACCOUNT ACCESS & DELEGATION 
#
#
#    @notice
#        Delegates are additional accounts that are allowed
#        to perform trading actions on behalf of a main account.
#        They can open/manage/close trades for another account.
#
#        This allows for example to have a main account protected
#        with a hardware wallet and use a hot wallet for daily trading.
#
#####################################

event DelegateAdded:
    account: indexed(address)
    delegate_account: indexed(address)


@external
def add_delegate(_delegate: address):
    """
    @notice
        Allows _delegate to perform any trading actions
        on behalf of msg.sender.
    """
    assert _delegate != empty(address), "zero address cannot be delegate"
    assert self.is_delegate[msg.sender][_delegate] == False, "is already delegate"
    self.is_delegate[msg.sender][_delegate] = True
    log DelegateAdded(msg.sender, _delegate)


event DelegateRemoved:
    account: indexed(address)
    delegate_account: indexed(address)

@external
def remove_delegate(_delegate: address):
    """
    @notice
        Removes a _delegates permission to execute
        trading actions on behalf of msg.sender.
    """
    assert self.is_delegate[msg.sender][_delegate] == True, "is not a delegate"
    self.is_delegate[msg.sender][_delegate] = False
    log DelegateRemoved(msg.sender, _delegate)
    

#####################################
#
#               UTIL 
#
#####################################

@internal
def _generate_uid() -> bytes32:
    uid: bytes32 = keccak256(_abi_encode(chain.id, self.uid_nonce, block.timestamp))
    self.uid_nonce += 1
    return uid


#####################################
#
#              ADMIN 
#
#####################################

event NewAdminSuggested:
    new_admin: indexed(address)
    suggested_by: indexed(address)

@external
def suggest_admin(_new_admin: address):
    """
    @notice
        Step 1 of the 2 step process to transfer adminship.
        Current admin suggests a new admin.
        Requires the new admin to accept adminship in step 2.
    @param _new_admin
        The address of the new admin.
    """
    assert msg.sender == self.admin, "unauthorized"
    assert _new_admin != self.admin, "already admin"
    self.suggested_admin = _new_admin
    log NewAdminSuggested(_new_admin, msg.sender)


event AdminTransferred:
    new_admin: indexed(address)
    promoted_by: indexed(address)

@external
def accept_admin():
    """
    @notice
        Step 2 of the 2 step process to transfer admin.
        The suggested admin accepts the transfer and becomes the
        new admin.
    """
    assert msg.sender == self.suggested_admin, "unauthorized"
    prev_admin: address = self.admin
    self.admin = self.suggested_admin
    self.suggested_admin = empty(address)

    log AdminTransferred(self.admin, prev_admin)

event AcceptingNewOrders:
    account: address
    is_accepting_new_orders: bool

@external
def set_is_accepting_new_orders(_is_accepting_new_orders: bool):
    """
    @notice
        Allows admin to put protocol in defensive or winddown mode.
        Open trades can still be completed but no new trades are accepted.
    """
    assert msg.sender == self.admin, "unauthorized"
    self.is_accepting_new_orders = _is_accepting_new_orders

    log AcceptingNewOrders(msg.sender, _is_accepting_new_orders)


event ApprovalUpdated:
    approved_by: address
    token: address
    spender: address
    amount: uint256

@external
def update_approval(_token: address, _spender: address, _amount: uint256):
    assert msg.sender == self.admin, "unauthorized"
    ERC20(_token).approve(_spender, _amount)

    log ApprovalUpdated(msg.sender, _token, _spender, _amount)


event LeverageBufferUpdated:
    updated_by: address
    leverage_buffer: uint256

@external
def set_leverage_buffer(_leverage_buffer: uint256):
    """
    @notice
        Sets the value by which the leverage after executing
        a TP or SL order may change.
    """
    assert msg.sender == self.admin, "unauthorized"
    self.leverage_buffer = _leverage_buffer

    log LeverageBufferUpdated(msg.sender, _leverage_buffer)


event SwapRouterUpdated:
    updated_by: address
    swap_router: address

@external
def set_swap_router(_swap_router: address):
    """
    @notice
        Sets the swap_router used to executed token swaps.
    """
    assert msg.sender == self.admin, "unauthorized"
    self.swap_router = _swap_router

    log SwapRouterUpdated(msg.sender, _swap_router)


event WhitelistedCallerUpdated:
    caller: address
    is_whitelisted: bool

@external
def set_is_whitelisted_caller(_is_whitelisted: bool):
    assert self.is_whitelisted_caller[msg.sender] != _is_whitelisted, "already set"
    self.is_whitelisted_caller[msg.sender] = _is_whitelisted
    log WhitelistedCallerUpdated(msg.sender, _is_whitelisted)


@internal
def _swap(
    _token_in: address,
    _token_out: address,
    _amount_in: uint256,
    _min_amount_out: uint256,
) -> uint256:
    """
    @notice
        Triggers a swap in the referenced swap_router.
        Ensures min_amount_out is respected.
    """

    return SwapRouter(self.swap_router).swap(
        _token_in, _token_out, _amount_in, _min_amount_out
    )

@internal
def _swap_exact_out(
    _token_in: address,
    _token_out: address,
    _amount_out: uint256,
    _max_amount_in: uint256,
) -> uint256:
    """
    @notice
        Triggers a swap in the referenced swap_router.
    """
    return SwapRouter(self.swap_router).swap_exact_out(
        _token_in, _token_out, _amount_out, _max_amount_in
    )


#####################################
#
#     Swap Callback Receiver
#
#####################################

interface P2PSwapper:
    def flash_callback(
        _tokens: address[3],
        _amounts_in: uint256[3],
        _data: Bytes[1024],
    ) -> (uint256, uint256, uint256): nonpayable


@nonreentrant("callback")
@external
def flash_callback(
        _token: address[3],  # [debt_token, margin_token, position_token]
        _amount_in: uint256[3], # [debt_amount_in, margin_amount_in, position_amount_in]
        _data: Bytes[1024],
    ) -> (uint256, uint256, uint256): # (actual_debt, actual_margin, actual_position)
    
    swap_sequence: uint256[5][3] = _abi_decode(_data, uint256[5][3])

    actual_outs: uint256[3] = empty(uint256[3])

    for s in swap_sequence:
        if s[0] == 0 and s[1] == 0: 
            continue

        token_in: address = _token[s[0]]
        token_out: address = _token[s[1]]
        swap_type: uint256 = s[2]
        amount_in: uint256 = min(ERC20(token_in).balanceOf(self), s[3])
        amount_out: uint256 = s[4]

        if amount_in == 0:
            # nothing to do
            continue

        if token_in == token_out:
            actual_outs[s[1]] += amount_in
            if actual_outs[s[0]] > amount_in:
                actual_outs[s[0]] -= amount_in
            else:
                actual_outs[s[0]] = 0
            continue


        if swap_type == 0: # exact_in
            actual_out: uint256 = self._swap(token_in, token_out, amount_in, amount_out)
            actual_outs[s[1]] += actual_out
            if actual_outs[s[0]] > 0:
                if actual_outs[s[0]] >= amount_in:
                    actual_outs[s[0]] -= amount_in
                else:
                    actual_outs[s[0]] = 0

        if swap_type == 1: # exact_out
            actual_in: uint256 = self._swap_exact_out(token_in, token_out, amount_out, amount_in)
            actual_outs[s[1]] += amount_out
            actual_outs[s[0]] += amount_in-actual_in

        if swap_type == 2: # exact_actual_out
            remaining_needed: uint256 = amount_out - ERC20(token_out).balanceOf(self)
            if remaining_needed > 0:
                actual_in: uint256 = self._swap_exact_out(token_in, token_out, remaining_needed, amount_in)
                actual_outs[s[1]] += remaining_needed
                actual_outs[s[0]] += amount_in-actual_in
            else:
                actual_outs[s[0]] += amount_in

    return (
        actual_outs[0],
        actual_outs[1],
        actual_outs[2],
    )
    
