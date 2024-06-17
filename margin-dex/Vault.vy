# @version 0.3.10
# pragma optimize codesize

###################################################################
#
# @title Unstoppable Margin DEX - Vault
# @license GNU AGPLv3
# @author unstoppable.ooo
#
# @custom:security-contact team@unstoppable.ooo
#
# @notice
#    This contract is part of the Unstoppable Margin DEX.
#
#    It handles all assets and allows whitelisted contracts
#    to create undercollateralized loan positions for users
#    that are then used to gain leveraged spot exposure to
#    an underlying asset.
#
###################################################################

interface ERC20:
    def decimals() -> uint8: view
    def balanceOf(_account: address) -> uint256: view

interface ChainlinkOracle:
    def latestRoundData() -> (
      uint80,  # roundId,
      int256,  # answer,
      uint256, # startedAt,
      uint256, # updatedAt,
      uint80   # answeredInRound
    ): view

interface P2PSwapper:
    def flash_callback(
        _tokens: address[3],
        _amounts_in: uint256[3],
        _data: Bytes[1024],
    ) -> (uint256, uint256, uint256): nonpayable

interface InterestRateConfiguration:
    def interest_rate_by_utilization(_address: address, _utilization_rate: uint256) -> uint256: view

interface FeeConfiguration:
    def get_fee_for_account(_account: address, _token_amount: uint256, _token_in: address, _token_out: address) -> uint256: view

interface Weth:
    def deposit(): payable
    def withdrawTo(_account: address, _amount: uint256): nonpayable


PRECISION: constant(uint256) = 10**18

SECONDS_PER_YEAR: constant(uint256) = 365 * 24 * 60 * 60
PERCENTAGE_BASE: constant(uint256) = 100_00 # == 100%
PERCENTAGE_BASE_HIGH_PRECISION: constant(uint256) = 100_00_000  # == 100%

ARBITRUM_SEQUENCER_UPTIME_FEED: constant(address) = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D

WETH: constant(address) = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1

interest_rate_config: public(address)
fee_config: public(address)

# whitelisted addresses allowed to interact with this vault
is_whitelisted_dex: public(HashMap[address, bool])

# address -> bool
is_whitelisted_token: public(HashMap[address, bool])
# token_in -> token_out
is_enabled_market: public(HashMap[address, HashMap[address, bool]])
# per market token_in -> token_out -> max_leverage
max_leverage: public(HashMap[address, HashMap[address, uint256]])
# token_in -> token_out -> margin_token -> enabled 
is_allowed_margin: public(HashMap[address, HashMap[address, HashMap[address, bool]]])
# margin_token -> max_leverage
max_leverage_when_used_as_margin: public(HashMap[address, uint256])
# token -> Chainlink oracle
to_usd_oracle: public(HashMap[address, address])
oracle_freshness_threshold: HashMap[address, uint256]

liquidation_bonus: public(uint256) # in PERCENTAGE_BASE
reasonable_price_impact: public(HashMap[address, uint256]) # in PERCENTAGE_BASE
price_impact_multiplier: public(uint256)

liquidation_penalty: public(uint256)
protocol_fee_receiver: public(address)
protocol_fees: public(HashMap[address, uint256])

# trader margin balances
margin: public(HashMap[address, HashMap[address, uint256]])

# Liquidity
# cooldown to prevent flashloan deposit/withdraws
withdraw_liquidity_cooldown: public(uint256)
account_withdraw_liquidity_cooldown: public(HashMap[address, uint256])

# Base LPs
base_lp_shares: public(HashMap[address, HashMap[address, uint256]])
base_lp_total_shares: public(HashMap[address, uint256])
base_lp_total_amount: public(HashMap[address, uint256])

# Safety Module LPs
safety_module_lp_shares: public(HashMap[address, HashMap[address, uint256]])
safety_module_lp_total_shares: public(HashMap[address, uint256])
safety_module_lp_total_amount: public(HashMap[address, uint256])

safety_module_interest_share_percentage: public(uint256)

# needed to track initial debt vs accrued interest
position_initial_debt_share_value: public(HashMap[bytes32, uint256])

# debt_token -> total_debt_shares
total_debt_shares: public(HashMap[address, uint256])
# debt_token -> Position uid -> debt_shares
debt_shares: public(HashMap[address, HashMap[bytes32, uint256]])
# debt_token -> total_debt
total_debt_amount: public(HashMap[address, uint256])
# debt_token -> timestamp
last_debt_update: HashMap[address, uint256]

# token -> bad_debt
bad_debt: public(HashMap[address, uint256])
acceptable_amount_of_bad_debt: public(HashMap[address, uint256])
bad_debt_liquidations_allowed: public(bool) # allowed by any liquidator
is_whitelisted_liquidator: public(HashMap[address, bool])

struct Position:
    uid: bytes32
    account: address
    margin_token: address
    margin_amount: uint256
    debt_token: address
    debt_shares: uint256
    position_token: address
    position_amount: uint256

# uid -> Position
positions: public(HashMap[bytes32, Position])

uid_nonce: uint256

admin: public(address)
suggested_admin: public(address)
is_accepting_new_orders: public(bool)


@external
def __init__():
    self.admin = msg.sender
    self.protocol_fee_receiver = msg.sender


event PositionOpened:
    account: indexed(address)
    position: Position

@nonreentrant("lock")
@external
def open_position(
    _caller: address,
    _account: address,
    _position_token: address,
    _min_position_amount: uint256,
    _debt_token: address,
    _debt_amount: uint256,
    _margin_token: address,
    _margin_amount: uint256,
    _data: Bytes[1024],
) -> bytes32:
    """
    @notice
        Creates a new undercollateralized loan for _account
        and uses it to assume a leveraged spot position in
        _position_token.
    """
    assert self.is_accepting_new_orders, "paused"
    assert self.is_whitelisted_dex[msg.sender], "unauthorized"
    assert self.is_enabled_market[_debt_token][_position_token], "market not enabled"
    assert self.is_allowed_margin[_debt_token][_position_token][_margin_token], "margin not allowed"
    assert self._available_liquidity(_debt_token) >= _debt_amount, "insufficient liquidity"

    if _margin_token != _debt_token:
        assert self.is_whitelisted_token[_margin_token], "invalid margin token"

    self._debit_margin(_account, _margin_token, _margin_amount)

    position_uid: bytes32 = self._generate_uid()
    debt_shares: uint256 = self._borrow(position_uid, _debt_token, _debt_amount)

    # charge fee
    fee: uint256 = FeeConfiguration(self.fee_config).get_fee_for_account(_account, _debt_amount, _debt_token, _position_token)
    if _margin_token != _debt_token:
        fee = self._quote(_debt_token, _margin_token, fee)
    self._debit_margin(_account, _margin_token, fee)
    self.protocol_fees[_margin_token] += fee
    log FeePaid(_account, _margin_token, fee)
    
    # send debt back to caller
    self._safe_transfer(_debt_token, _caller, _debt_amount)


    position_amount: uint256 = _min_position_amount
    # ----- flash callback -----
    if _data != empty(Bytes[1024]):
        actual_position_amount: uint256 = P2PSwapper(_caller).flash_callback(
            [_debt_token, _margin_token, _position_token],
            [_debt_amount, 0, 0],
            _data
        )[2]
        assert actual_position_amount >= _min_position_amount, "[Vault::open] too little out"
        position_amount = actual_position_amount

    assert _debt_amount < (self._quote(_position_token, _debt_token, position_amount) * (PERCENTAGE_BASE + (self.reasonable_price_impact[_position_token] * self.price_impact_multiplier)) / PERCENTAGE_BASE), "expecting too much out"

    # transfer position in from _caller
    self._safe_transfer_from(_position_token, _caller, self, position_amount)

    self.positions[position_uid] = Position(
        {
            uid: position_uid,
            account: _account,
            margin_token: _margin_token,
            margin_amount: _margin_amount,
            debt_token: _debt_token,
            debt_shares: debt_shares,
            position_token: _position_token,
            position_amount: position_amount,
        }
    )

    log PositionOpened(_account, self.positions[position_uid])

    assert not self._is_liquidatable(position_uid), "cannot open liquidatable position"

    return position_uid


event PositionClosed:
    uid: bytes32
    
event PositionChanged:
    uid: bytes32
    position: Position

event BadDebt:
    token: address
    amount: uint256
    position_uid: bytes32

event FeePaid:
    account: address
    token: address
    fee: uint256

event Liquidation:
    uid: bytes32
    token: address
    amount: uint256

@nonreentrant("lock")
@external
def change_position(
    _caller: address,
    _position_uid: bytes32,
    _debt_change: int256,                 # in debt_token
    _margin_change: int256,               # in margin_token
    _position_change: int256,             # in position_token
    _realized_pnl: int256,                # in margin_token
    _data: Bytes[1024],                   # callback data
    _allow_higher_price_impact: bool = False,
):
    """
    @notice
        Changes an existing position by adding or removing debt/position/margin.
    """
    assert self.is_whitelisted_dex[msg.sender], "unauthorized"
    
    position: Position = self.positions[_position_uid]
    position_debt_amount: uint256 = self._debt(_position_uid)

    is_liquidation: bool = self._is_liquidatable(_position_uid)
    bad_debt_before: uint256 = self.bad_debt[position.debt_token]

    amount_in: uint256[3] = [0, 0, 0]      # [debt, margin, position] <- sequence is important
    amount_out: uint256[3] = [0, 0, 0]     # [debt, margin, position]
    if _debt_change < 0:
        amount_out[0] = convert(abs(_debt_change), uint256)
        
        # pay interest accrued on current debt
        amount_interest: uint256 = (self._amount_per_debt_share(position.debt_token) - self.position_initial_debt_share_value[_position_uid]) * position.debt_shares / PRECISION / PRECISION
        self._pay_interest_to_lps(position.debt_token, amount_interest)
        
        # take out new debt, this resets the accounting for interest
        new_debt_shares: uint256 = self._borrow(_position_uid, position.debt_token, amount_out[0])
        position.debt_shares += new_debt_shares
        
        # charge fee
        fee: uint256 = FeeConfiguration(self.fee_config).get_fee_for_account(position.account, amount_out[0], position.debt_token, position.position_token)
        if position.margin_token != position.debt_token:
            fee = self._quote(position.debt_token, position.margin_token, fee)
        self._debit_margin(position.account, position.margin_token, fee)
        self.protocol_fees[position.margin_token] += fee
        log FeePaid(position.account, position.margin_token, fee)
    else:
        amount_in[0] = min(position_debt_amount, convert(_debt_change, uint256))

    if _margin_change < 0:
        amount_out[1] = convert(abs(_margin_change), uint256)
        if amount_out[1] != position.margin_amount and position.margin_token != position.debt_token:
            # round so we don't leak wei
            amount_out[1] = self._quote(position.debt_token, position.margin_token, self._quote(position.margin_token, position.debt_token, amount_out[1]))
        position.margin_amount -= amount_out[1]
    else:
        amount_in[1] = convert(_margin_change, uint256)

    if _position_change < 0:
        amount_out[2] = convert(abs(_position_change), uint256)
        if amount_out[2] != position.position_amount:
            # round so we don't leak wei
            amount_out[2] = self._quote(position.debt_token, position.position_token, self._quote(position.position_token, position.debt_token, amount_out[2]))
        position.position_amount -= amount_out[2]
    else:
        amount_in[2] = convert(_position_change, uint256)


    price_impact_multiplier: uint256 = 1
    if _allow_higher_price_impact:
        price_impact_multiplier = self.price_impact_multiplier

    # ----- ensure p2p swap is fair ------
    caller_expected_value_out: uint256 = amount_out[0]
    if amount_out[1] > 0:
        caller_expected_value_out += self._quote(position.margin_token, position.debt_token, amount_out[1])
    if amount_out[2] > 0:
        caller_expected_value_out += self._quote(position.position_token, position.debt_token, amount_out[2])
    
    max_reasonable_value_out: uint256 = amount_in[0] * (PERCENTAGE_BASE + self.reasonable_price_impact[position.debt_token]*price_impact_multiplier) / PERCENTAGE_BASE
    if amount_in[1] > 0:
        max_reasonable_value_out += self._quote(position.margin_token, position.debt_token, amount_in[1]) * (PERCENTAGE_BASE + self.reasonable_price_impact[position.margin_token]*price_impact_multiplier) / PERCENTAGE_BASE
    if amount_in[2] > 0:
        max_reasonable_value_out += self._quote(position.position_token, position.debt_token, amount_in[2]) * (PERCENTAGE_BASE + self.reasonable_price_impact[position.position_token]*price_impact_multiplier) / PERCENTAGE_BASE
        
    if is_liquidation:
        max_reasonable_value_out = max_reasonable_value_out * (PERCENTAGE_BASE + self.liquidation_bonus) / PERCENTAGE_BASE

    assert caller_expected_value_out <= max_reasonable_value_out, "expecting too much amount_out"
    #/end ----- ensure p2p swap is fair ------


    # send amount_out[]
    if amount_out[0] > 0:
        self._safe_transfer(position.debt_token, _caller, amount_out[0])
    if amount_out[1] > 0:
        self._safe_transfer(position.margin_token, _caller, amount_out[1])
    if amount_out[2] > 0:
        self._safe_transfer(position.position_token, _caller, amount_out[2])


    # flash callback
    actual_debt_in: uint256 = amount_in[0]
    actual_margin_in: uint256 = amount_in[1]
    actual_pos_in: uint256 = amount_in[2]
    if _data != empty(Bytes[1024]):
        (actual_debt_in, actual_margin_in, actual_pos_in) = P2PSwapper(_caller).flash_callback(
            [position.debt_token, position.margin_token, position.position_token],
            amount_out, 
            _data
        )
        # a good faith _caller might get better exchange rates in the callback than expected and pass that on to the trader
        # amount_in = [debt, margin, position]
        assert actual_debt_in >= amount_in[0], "[Vault:cb] too little debt"
        assert actual_margin_in >= amount_in[1], "[Vault:cb] too little margin"
        assert actual_pos_in >= amount_in[2], "[Vault:cb] too little position"


    # collect amount_in[position]
    if actual_pos_in > 0:
        position.position_amount += actual_pos_in
        self._safe_transfer_from(position.position_token, _caller, self, actual_pos_in)

        # collect amount_in[margin]
    if actual_margin_in > 0:
        self._safe_transfer_from(position.margin_token, _caller, self, actual_margin_in)
        position.margin_amount += actual_margin_in

    # account realized PnL
    realized_pnl: uint256 = convert(abs(_realized_pnl), uint256)
    if _realized_pnl < 0:
        self._credit_margin(position.account, position.margin_token, realized_pnl)
        position.margin_amount -= realized_pnl
    else:
        self._debit_margin(position.account, position.margin_token, realized_pnl)
        position.margin_amount += realized_pnl


    # collect amount_in[debt]
    if actual_debt_in > 0:
        debt_shares_to_repay: uint256 = 0
        if actual_debt_in >= position_debt_amount:
            # must be a full close
            debt_shares_to_repay = position.debt_shares
            if actual_debt_in > position_debt_amount:
                # credit excess debt to user in debt_token
                self._credit_margin(position.account, position.debt_token, actual_debt_in - position_debt_amount)
        else:
            debt_shares_to_repay = self._amount_to_debt_shares(position.debt_token, actual_debt_in)
        self._repay(_position_uid, position.debt_token, debt_shares_to_repay)
        position.debt_shares -= debt_shares_to_repay
        
        if position.position_amount == 0:
            # no position left -> full close
            if position.debt_shares > 0:
                # bad debt case
                assert position.margin_amount == 0, "use margin to lower bad_debt"
                assert _realized_pnl == 0, "cannot realize profit in bad_debt"
                bad_debt_amount: uint256 = self._debt_shares_to_amount(position.debt_token, position.debt_shares)
                self._repay(_position_uid, position.debt_token, position.debt_shares) 
                position.debt_shares = 0
                self.bad_debt[position.debt_token] += bad_debt_amount
                log BadDebt(position.debt_token, bad_debt_amount, _position_uid)
                if self.bad_debt[position.debt_token] > self.acceptable_amount_of_bad_debt[position.debt_token]:
                    self.is_accepting_new_orders = False

        self._safe_transfer_from(position.debt_token, _caller, self, actual_debt_in)

    if is_liquidation:
        assert _debt_change > 0, "cannot take on more debt in liquidation"
        assert _realized_pnl == 0, "cannot move margin in liquidation"
        assert _position_change <= 0, "cannot increase position in liquidation"

        # apply liquidation penalty
        penalty: uint256 = actual_debt_in * self.liquidation_penalty / PERCENTAGE_BASE
        if position.position_amount > 0:
            # partial liquidation, penalty from new debt
            assert _margin_change <= 0, "cannot add margin during partial liquidation"

            # pay interest accrued on current debt
            amount_interest: uint256 = (
                (
                    self._amount_per_debt_share(position.debt_token)
                    - self.position_initial_debt_share_value[_position_uid]
                )
                * position.debt_shares
                / PRECISION
                / PRECISION
            )
            self._pay_interest_to_lps(position.debt_token, amount_interest)

            new_debt_shares: uint256 = self._borrow(_position_uid, position.debt_token, penalty)
            position.debt_shares += new_debt_shares
            self.protocol_fees[position.debt_token] += penalty
            log Liquidation(_position_uid, position.debt_token, penalty)

        else:
            # full liquidation, penalty from margin
            if position.margin_token != position.debt_token:
                penalty = self._quote(position.debt_token, position.margin_token, penalty)
            penalty = min(penalty, position.margin_amount)
            position.margin_amount -= penalty
            self.protocol_fees[position.margin_token] += penalty
            log Liquidation(_position_uid, position.margin_token, penalty)

    
    self.positions[_position_uid] = position

    if (self.bad_debt[position.debt_token] > bad_debt_before) or (self._effective_leverage(_position_uid, 0) == max_value(uint256)):
        assert self.is_whitelisted_liquidator[_caller] or self.bad_debt_liquidations_allowed, "only whitelisted liquidators allowed to create bad debt"

    if position.debt_shares == 0 or position.position_amount == 0:
        # no position left, no debt left -> full close
        assert position.debt_shares == 0 and position.position_amount == 0, "debt and position must to be fully closed"

        if position.margin_amount > 0:
            self._credit_margin(position.account, position.margin_token, position.margin_amount)

        self.positions[_position_uid] = empty(Position)
        log PositionClosed(_position_uid)
        return

    log PositionChanged(_position_uid, position)

    if not is_liquidation:
        assert self._is_liquidatable(_position_uid) == False, "cannot change position into liquidation"


#####################################
#
#        LEVERAGE & HEALTH
#
#####################################

@view
@external
def effective_leverage(_position_uid: bytes32, _decimals: uint256 = 0) -> uint256:
    return self._effective_leverage(_position_uid, _decimals)


@view
@internal
def _effective_leverage(_position_uid: bytes32, _decimals: uint256) -> uint256:
    """
    @notice
        Calculated the current leverage of a position based
        on the position current value, the underlying margin 
        and the accrued debt.
    """
    position: Position = self.positions[_position_uid]

    position_value: uint256 = self._in_usd(
        position.position_token, position.position_amount
    )
    debt_value: uint256 = self._in_usd(position.debt_token, self._debt(_position_uid))
    margin_value: uint256 = self._in_usd(position.margin_token, position.margin_amount)

    return self._calculate_leverage(position_value, debt_value, margin_value, _decimals)


@view
@internal
def _calculate_leverage(
    _position_value: uint256, _debt_value: uint256, _margin_value: uint256, _decimals: uint256
) -> uint256:
    """
    @notice
        We calculate leverage as the ratio between the debt of a position
        and the deposited margin +/- the running PnL.
    """
    if _position_value + _margin_value <= _debt_value:
        # bad debt
        return max_value(uint256)

    # debt / (margin + pnl)
    # pnl = _position_value - _debt_value

    return (
        PRECISION
        * 10**_decimals
        * _debt_value 
        / (_position_value + _margin_value - _debt_value)
        / PRECISION
    )


@view
@external
def is_liquidatable(_position_uid: bytes32) -> bool:
    return self._is_liquidatable(_position_uid)

@view
@internal
def _is_liquidatable(_position_uid: bytes32) -> bool:
    """
    @notice
        Checks if a position exceeds the maximum leverage
        allowed for that market.
    """
    leverage: uint256 = self._effective_leverage(_position_uid, 0)
    
    if leverage > self.max_leverage[self.positions[_position_uid].debt_token][self.positions[_position_uid].position_token]:
        # leverage exceeds max allowed leverage for market, always liquidatable
        return True

    if leverage > self.max_leverage_when_used_as_margin[self.positions[_position_uid].margin_token]:
        # leverage exceeds max allowed leverage for margin token
        return True
    
    return False


#####################################
#
#        ORACLE PRICE FEEDS
#
#####################################

@view
@external
def to_usd_oracle_price(_token: address) -> uint256:
    return self._to_usd_oracle_price(_token)

@view
@internal
def _to_usd_oracle_price(_token: address) -> uint256:
    """
    @notice
        Retrieves the latest Chainlink oracle price for _token.
        Ensures that the Arbitrum sequencer is up and running and
        that the Chainlink feed is fresh.
    """
    assert self._sequencer_up(), "sequencer down"

    round_id: uint80 = 0
    answer: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in_round: uint80 = 0
    round_id, answer, started_at, updated_at, answered_in_round = ChainlinkOracle(
        self.to_usd_oracle[_token]
    ).latestRoundData()

    assert (block.timestamp - updated_at) < self.oracle_freshness_threshold[self.to_usd_oracle[_token]], "oracle not fresh"

    usd_price: uint256 = convert(answer, uint256)  # 8 dec
    return usd_price


@view
@internal
def _sequencer_up() -> bool:
    # answer == 0: Sequencer is up
    # answer == 1: Sequencer is down
    answer: int256 = ChainlinkOracle(ARBITRUM_SEQUENCER_UPTIME_FEED).latestRoundData()[1]
    return answer == 0


@view
@internal
def _in_usd(_token: address, _amount: uint256) -> uint256:
    """
    @notice
        Converts _amount of _token to a USD value.
    """
    return (
        self._to_usd_oracle_price(_token)
        * _amount
        / 10 ** convert(ERC20(_token).decimals(), uint256)
    )


@view
@internal
def _quote(
    _token0: address, _token1: address, _amount0: uint256
) -> uint256:
    return (
        self._in_usd(_token0, _amount0) # amount0_in_usd
        * 10**convert(ERC20(_token1).decimals(), uint256) # token1_decimals 
        / self._to_usd_oracle_price(_token1) # token1_usd_price
    )


#####################################
#
#       USER ACCOUNTS / MARGIN
#
#####################################

event AccountFunded:
    account: indexed(address)
    amount: uint256
    token: indexed(address)


@nonreentrant("lock")
@payable
@external
def fund_account_eth():
    """
    @notice
        Allows a user to fund his WETH margin by depositing ETH.
    """
    assert self.is_accepting_new_orders, "funding paused"
    assert self.is_whitelisted_token[WETH], "token not whitelisted"
    self._credit_margin(msg.sender, WETH, msg.value)
    raw_call(WETH, method_id("deposit()"), value=msg.value)
    log AccountFunded(msg.sender, msg.value, WETH)


@nonreentrant("lock")
@external
def fund_account(_token: address, _amount: uint256):
    """
    @notice
        Allows a user to fund his _token margin.
    """
    assert self.is_accepting_new_orders, "funding paused"
    assert self.is_whitelisted_token[_token], "token not whitelisted"
    self._credit_margin(msg.sender, _token, _amount)
    self._safe_transfer_from(_token, msg.sender, self, _amount)
    log AccountFunded(msg.sender, _amount, _token)


event WithdrawBalance:
    account: indexed(address)
    token: indexed(address)
    amount: uint256


@nonreentrant("lock")
@external
def withdraw_from_account_eth(_amount: uint256):
    """
    @notice
        Allows a user to withdraw from his WETH margin and
        automatically swaps back to ETH.
    """
    self._debit_margin(msg.sender, WETH, _amount)
    raw_call(
        WETH,
        concat(
            method_id("withdrawTo(address,uint256)"),
            convert(msg.sender, bytes32),
            convert(_amount, bytes32),
        ),
    )
    log WithdrawBalance(msg.sender, WETH, _amount)


@nonreentrant("lock")
@external
def withdraw_from_account(_token: address, _amount: uint256):
    """
    @notice
        Allows a user to withdraw from his _token margin.
    """
    self._debit_margin(msg.sender, _token, _amount)
    self._safe_transfer(_token, msg.sender, _amount)
    log WithdrawBalance(msg.sender, _token, _amount)


@nonreentrant("lock")
@external
def swap_margin(
    _caller: address,
    _account: address,
    _token0: address,
    _token1: address,
    _amount0: uint256,
    _amount1: uint256,
    _data: Bytes[1024]
):
    """
    @notice
        Allows a user to swap his margin balances between different tokens.
    """
    assert self.is_whitelisted_dex[msg.sender], "unauthorized"
    assert self.is_whitelisted_token[_token1], "token not whitelisted"

    assert _amount1 >= (self._quote(_token0, _token1, _amount0) * (PERCENTAGE_BASE - self.reasonable_price_impact[_token0]) / PERCENTAGE_BASE), "unfair margin swap"

    self._debit_margin(_account, _token0, _amount0)
    self._safe_transfer(_token0, _caller, _amount0)

    amount1: uint256 = _amount1
    # flash callback
    if _data != empty(Bytes[1024]):
        actual_amount1: uint256 = P2PSwapper(_caller).flash_callback(
            [_token0, _token1, empty(address)],
            [_amount0, 0, 0], 
            _data
        )[1]
        assert actual_amount1 >= amount1, "[MS:cb] too little out"
        amount1 = actual_amount1
        
    self._credit_margin(_account, _token1, amount1)
    self._safe_transfer_from(_token1, _caller, self, amount1)


event MarginCredited:
    account: address
    token: address
    amount: uint256

event MarginDebited:
    account: address
    token: address
    amount: uint256

@internal
def _credit_margin(_account: address, _token: address, _amount: uint256):
    if _amount > 0:
        self.margin[_account][_token] += _amount
        log MarginCredited(_account, _token, _amount)

@internal
def _debit_margin(_account: address, _token: address, _amount: uint256):
    assert self.margin[_account][_token] >= _amount, "insufficient margin balance"
    if _amount > 0:
        self.margin[_account][_token] -= _amount
        log MarginDebited(_account, _token, _amount)


#####################################
#
#             LIQUIDITY 
#
#####################################

event ProvideLiquidity:
    account: indexed(address)
    token: indexed(address)
    amount: uint256



@nonreentrant("lock")
@external
def provide_liquidity(_token: address, _amount: uint256, _is_safety_module: bool):
    """
    @notice
        Allows LPs to provide _token liquidity.
    """
    assert self.is_accepting_new_orders, "LPing paused"

    assert self.is_whitelisted_token[_token], "token not whitelisted"

    self._account_for_provide_liquidity(_token, _amount, _is_safety_module)

    self._safe_transfer_from(_token, msg.sender, self, _amount)
    log ProvideLiquidity(msg.sender, _token, _amount)


@internal
def _account_for_provide_liquidity(
    _token: address, _amount: uint256, _is_safety_module: bool
):
    self._update_debt(_token)
    shares: uint256 = self._amount_to_lp_shares(_token, _amount, _is_safety_module)
    if _is_safety_module:
        self.safety_module_lp_total_shares[_token] += shares
        self.safety_module_lp_shares[_token][msg.sender] += shares
        self.safety_module_lp_total_amount[_token] += _amount

    else:
        self.base_lp_total_shares[_token] += shares
        self.base_lp_shares[_token][msg.sender] += shares
        self.base_lp_total_amount[_token] += _amount

    # record cooldown after which account can withdraw again
    self.account_withdraw_liquidity_cooldown[msg.sender] = (
        block.timestamp + self.withdraw_liquidity_cooldown
    )


event WithdrawLiquidity:
    account: indexed(address)
    token: indexed(address)
    amount: uint256


@nonreentrant("lock")
@external
def withdraw_liquidity(_token: address, _amount: uint256, _is_safety_module: bool):
    """
    @notice
        Allows LPs to withdraw their _token liquidity.
        Only liquidity that is currently not lent out can be withdrawn.
    """
    assert (self.account_withdraw_liquidity_cooldown[msg.sender] <= block.timestamp), "cooldown"

    assert _amount <= self._available_liquidity(_token), "liquidity not available"

    self._account_for_withdraw_liquidity(_token, _amount, _is_safety_module)

    self._safe_transfer(_token, msg.sender, _amount)
    log WithdrawLiquidity(msg.sender, _token, _amount)


@internal
def _account_for_withdraw_liquidity(
    _token: address, _amount: uint256, _is_safety_module: bool
):
    self._update_debt(_token)
    if _is_safety_module:
        shares: uint256 = self._amount_to_lp_shares(_token, _amount, True)
        assert (shares <= self.safety_module_lp_shares[_token][msg.sender]), "cannot withdraw more than you own"
        self.safety_module_lp_total_amount[_token] -= _amount
        self.safety_module_lp_total_shares[_token] -= shares
        self.safety_module_lp_shares[_token][msg.sender] -= shares

    else:
        shares: uint256 = self._amount_to_lp_shares(_token, _amount, False)
        assert (shares <= self.base_lp_shares[_token][msg.sender]), "cannot withdraw more than you own"
        self.base_lp_total_amount[_token] -= _amount
        self.base_lp_total_shares[_token] -= shares
        self.base_lp_shares[_token][msg.sender] -= shares


@internal
@view
def _amount_to_lp_shares(
    _token: address, _amount: uint256, _is_safety_module: bool
) -> uint256:
    if _is_safety_module:
        return _amount * (self.safety_module_lp_total_shares[_token] + PRECISION) / (self._safety_module_total_amount(_token) + 1)
    # base_lp
    return _amount * (self.base_lp_total_shares[_token] + PRECISION) / (self._base_lp_total_amount(_token) + 1)


@external
@view
def lp_shares_to_amount(
    _token: address, _shares: uint256, _is_safety_module: bool
) -> uint256:
    return self._lp_shares_to_amount(_token, _shares, _is_safety_module)


@internal
@view
def _lp_shares_to_amount(
    _token: address, _shares: uint256, _is_safety_module: bool
) -> uint256:

    if _is_safety_module:
        return _shares * (self._safety_module_total_amount(_token) + 1) / (self.safety_module_lp_total_shares[_token] + PRECISION)
    
    return _shares * (self._base_lp_total_amount(_token) + 1) / (self.base_lp_total_shares[_token] + PRECISION)


@internal
@view
def _base_lp_total_amount(_token: address) -> uint256:
    if self.bad_debt[_token] <= self.safety_module_lp_total_amount[_token]:
        # safety module covers all bad debt, base lp is healthy
        return self.base_lp_total_amount[_token]
    # more bad debt than covered by safety module, base lp is impacted as well
    return self.base_lp_total_amount[_token] + self.safety_module_lp_total_amount[_token] - self.bad_debt[_token]


@internal
@view
def _safety_module_total_amount(_token: address) -> uint256:
    if self.bad_debt[_token] > self.safety_module_lp_total_amount[_token]:
        return 0
    return self.safety_module_lp_total_amount[_token] - self.bad_debt[_token]


@internal
@view
def _total_liquidity(_token: address) -> uint256:
    return (
        self.base_lp_total_amount[_token]
        + self.safety_module_lp_total_amount[_token]
        - self.bad_debt[_token]
    )

@external
@view
def available_liquidity(_token: address) -> uint256:
    return self._available_liquidity(_token)


@internal
@view
def _available_liquidity(_token: address) -> uint256:
    if self.total_debt_amount[_token] > self._total_liquidity(_token):
        return 0
    return self._total_liquidity(_token) - self.total_debt_amount[_token]


#####################################
#
#               DEBT
#
#####################################
event Borrow:
    position_uid: bytes32
    token: address
    amount: uint256
    shares: uint256

@internal
def _borrow(_uid: bytes32, _debt_token: address, _amount: uint256) -> uint256:
    self._update_debt(_debt_token)

    assert _amount <= self._available_liquidity(_debt_token), "not enough liquidity"

    debt_shares: uint256 = self._amount_to_debt_shares(_debt_token, _amount)

    self.total_debt_amount[_debt_token] += _amount
    self.total_debt_shares[_debt_token] += debt_shares

    self.position_initial_debt_share_value[_uid] = self._amount_per_debt_share(_debt_token)

    log Borrow(_uid, _debt_token, _amount, debt_shares)

    return debt_shares


event Repay:
    position_uid: bytes32
    token: address
    amount: uint256
    shares: uint256

@internal
def _repay(_uid: bytes32, _debt_token: address, _shares: uint256):
    self._update_debt(_debt_token)

    debt_amount: uint256 = self._debt_shares_to_amount(_debt_token, _shares)
    amount_interest: uint256 = (self._amount_per_debt_share(_debt_token) - self.position_initial_debt_share_value[_uid]) * _shares / PRECISION / PRECISION
    self._pay_interest_to_lps(_debt_token, amount_interest)

    self.total_debt_amount[_debt_token] -= debt_amount
    self.total_debt_shares[_debt_token] -= _shares

    log Repay(_uid, _debt_token, debt_amount, _shares)


@internal
def _update_debt(_debt_token: address):
    """
    @notice
        Accounts for any accrued interest since the last update.
    """
    if block.timestamp == self.last_debt_update[_debt_token]:
        return  # already up to date, nothing to do

    if self.total_debt_amount[_debt_token] == 0:
        self.last_debt_update[_debt_token] = block.timestamp
        return # no debt, no interest

    self.total_debt_amount[_debt_token] += self._debt_interest_since_last_update(
        _debt_token
    )

    self.last_debt_update[_debt_token] = block.timestamp


@internal
@view
def _debt_interest_since_last_update(_debt_token: address) -> uint256:
    return (
        (block.timestamp - self.last_debt_update[_debt_token])
        * self._current_interest_per_second(_debt_token)
        * self.total_debt_amount[_debt_token]
        / PERCENTAGE_BASE_HIGH_PRECISION
        / PRECISION
    )


@internal
@view
def _amount_to_debt_shares(_debt_token: address, _amount: uint256) -> uint256:
    # initial shares == wei * PRECISION
    if self.total_debt_shares[_debt_token] == 0:
        return _amount * PRECISION

    return _amount * PRECISION * PRECISION / self._amount_per_debt_share(_debt_token)


@external
@view
def debt_shares_to_amount(_debt_token: address, _shares: uint256) -> uint256:
    return self._debt_shares_to_amount(_debt_token, _shares)


@internal
@view
def _debt_shares_to_amount(
    _debt_token: address,
    _shares: uint256,
) -> uint256:
    if _shares == 0:
        return 0

    return _shares * self._amount_per_debt_share(_debt_token) / PRECISION / PRECISION


@internal
@view
def _amount_per_debt_share(_debt_token: address) -> uint256:
    # @dev returns extra 18 decimals for precision!
    if self.total_debt_shares[_debt_token] == 0:
        return 0
    
    return (
        self._total_debt_plus_pending_interest(_debt_token)
        * PRECISION
        * PRECISION
        / self.total_debt_shares[_debt_token]
    )

@internal
@view
def _total_debt_plus_pending_interest(_debt_token: address) -> uint256:
    return self.total_debt_amount[_debt_token] + self._debt_interest_since_last_update(
        _debt_token
    )


@external
@view
def debt(_position_uid: bytes32) -> uint256:
    """
    @notice
        Returns the current debt amount a position has accrued
        (inital debt borrowed + interest).
    """
    return self._debt(_position_uid)


@internal
@view
def _debt(_position_uid: bytes32) -> uint256:
    return self._debt_shares_to_amount(
        self.positions[_position_uid].debt_token,
        self.positions[_position_uid].debt_shares,
    ) + 1 # plus one for rounding
    

#####################################
#
#             INTEREST
#
#####################################

@external
@view
def current_interest_per_second(_debt_token: address) -> uint256:
    return self._current_interest_per_second(_debt_token)

@internal
@view
def _current_interest_per_second(_debt_token: address) -> uint256:
    utilization_rate: uint256 = self._utilization_rate(_debt_token) 
    interest_rate: uint256 = self._interest_rate_by_utilization(
        _debt_token, utilization_rate
    )
    interest_per_second: uint256 = interest_rate * PRECISION / SECONDS_PER_YEAR
    return interest_per_second

@internal
@view
def _utilization_rate(_debt_token: address) -> uint256:
    """
    @notice
        Returns the current utilization rate of _debt_token
        (liquidity provided vs amount borrowed).
    """
    return (
        (
            PRECISION
            - (
                self._available_liquidity(_debt_token)
                * PRECISION
                / self._total_liquidity(_debt_token)
            )
        )
        * PERCENTAGE_BASE_HIGH_PRECISION
        / PRECISION
    )

@internal
@view
def _interest_rate_by_utilization(
    _address: address, _utilization_rate: uint256
) -> uint256:
    """
    @notice
        calls the external contract with the interest rate configuration
    """
    return InterestRateConfiguration(self.interest_rate_config).interest_rate_by_utilization(_address, _utilization_rate)


event InterestPaid:
    token: address
    amount: uint256

@internal
def _pay_interest_to_lps(_token: address, _amount: uint256):
    safety_module_amount: uint256 = (
        _amount * self.safety_module_interest_share_percentage / PERCENTAGE_BASE
    )
    self.safety_module_lp_total_amount[_token] += safety_module_amount
    self.base_lp_total_amount[_token] += _amount - safety_module_amount

    log InterestPaid(_token, _amount)


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


@internal
def _safe_transfer(_token: address, _to: address, _amount: uint256) -> bool:
    res: Bytes[32] = raw_call(
        _token,
        concat(
            method_id("transfer(address,uint256)"),
            convert(_to, bytes32),
            convert(_amount, bytes32),
        ),
        max_outsize=32,
    )
    if len(res) > 0:
        assert convert(res, bool), "transfer failed"

    return True


@internal
def _safe_transfer_from(
    _token: address, _from: address, _to: address, _amount: uint256
) -> bool:
    res: Bytes[32] = raw_call(
        _token,
        concat(
            method_id("transferFrom(address,address,uint256)"),
            convert(_from, bytes32),
            convert(_to, bytes32),
            convert(_amount, bytes32),
        ),
        max_outsize=32,
    )
    if len(res) > 0:
        assert convert(res, bool), "transfer failed"

    return True


event BadDebtRepaid:
    token: indexed(address)
    amount: uint256

@nonreentrant("lock")
@external
def repay_bad_debt(_token: address, _amount: uint256):
    """
    @notice
        Allows to repay bad_debt in case it was accrued.
    """
    self.bad_debt[_token] -= _amount
    self._safe_transfer_from(_token, msg.sender, self, _amount)

    log BadDebtRepaid(_token, _amount)


event FeesClaimed:
    receiver: indexed(address)
    token: indexed(address)
    amount: uint256

@nonreentrant("lock")
@external
def claim_protocol_fees(_token: address):
    amount_to_claim: uint256 = self.protocol_fees[_token]
    assert amount_to_claim > 0, "nothing to claim"
    self.protocol_fees[_token] = 0
    self._safe_transfer(_token, self.protocol_fee_receiver, amount_to_claim)

    log FeesClaimed(self.protocol_fee_receiver, _token, amount_to_claim)


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
        Allows admin to put protocol in defensive or winddown mode or reactivate normal mode.
        Open Positions can still be managed but no new positions are accepted.
    """
    assert msg.sender == self.admin, "unauthorized"
    self.is_accepting_new_orders = _is_accepting_new_orders
    log AcceptingNewOrders(msg.sender, _is_accepting_new_orders)


#
# allowed tokens & markets
#

event TokenWhitelistUpdate:
    updated_by: address
    token: address
    token_to_usd_oracle: address
    oracle_freshness_threshold: uint256
    is_whitelisted: bool
    max_leverage_when_used_as_margin: uint256

@external
def update_token_whitelist(
    _token: address, 
    _token_to_usd_oracle: address, 
    _oracle_freshness_threshold: uint256,
    _is_whitelisted: bool,
    _max_leverage_when_used_as_margin: uint256,
    _acceptable_amount_of_bad_debt: uint256,
    _reasonable_price_impact: uint256) -> uint256:
    assert msg.sender == self.admin, "unauthorized"
    
    if _is_whitelisted:
        assert _token_to_usd_oracle != empty(address), "empty oracle address"
        assert _oracle_freshness_threshold > 0, "invalid oracle freshness threshold"
        self.is_whitelisted_token[_token] = True
        self.to_usd_oracle[_token] = _token_to_usd_oracle
        self.oracle_freshness_threshold[_token_to_usd_oracle] = _oracle_freshness_threshold
        self.max_leverage_when_used_as_margin[_token] = _max_leverage_when_used_as_margin
        self.acceptable_amount_of_bad_debt[_token] = _acceptable_amount_of_bad_debt
        self.reasonable_price_impact[_token] = _reasonable_price_impact
        return self._to_usd_oracle_price(_token) # ensures contract support Chainlink interface & manual sanity check
    else:
        assert self.is_whitelisted_token[_token] == True, "is not whitelisted"
        self.is_whitelisted_token[_token] = False
        self.oracle_freshness_threshold[self.to_usd_oracle[_token]] = 0
        self.to_usd_oracle[_token] = empty(address)
        self.max_leverage_when_used_as_margin[_token] = 0
        return 0
    
    log TokenWhitelistUpdate(msg.sender, _token, _token_to_usd_oracle, _oracle_freshness_threshold, _is_whitelisted, _max_leverage_when_used_as_margin)
        

event MarketUpdated:
    updated_by: address
    token1: address
    token2: address
    max_leverage: uint256
    is_enabled: bool

@external
def update_market(_token1: address, _token2: address, _max_leverage: uint256, _is_enabled: bool):
    assert msg.sender == self.admin, "unauthorized"

    assert (self.is_whitelisted_token[_token1] and self.is_whitelisted_token[_token2]), "invalid token"

    self.max_leverage[_token1][_token2] = _max_leverage
    self.is_enabled_market[_token1][_token2] = _is_enabled

    log MarketUpdated(msg.sender, _token1, _token2, _max_leverage, _is_enabled)


event MarginTokenUpdated:
    token_in: address
    token_out: address
    margin_token: address
    enabled: bool

@external
def update_margin_token(_token_in: address, _token_out: address, _margin_token: address, _enabled: bool):
    assert msg.sender == self.admin, "unauthorized"
    self.is_allowed_margin[_token_in][_token_out][_margin_token] = _enabled
    log MarginTokenUpdated(_token_in, _token_out, _margin_token, _enabled)
    

#
# configuration
#
event ConfigurationUpdated:
    updated_by: address
    liquidation_penalty: uint256
    trading_fee_safety_module_interest_share_percentage: uint256
    fee_config: address
    interest_rate_config: address
    withdraw_liquidity_cooldown: uint256
    fee_receiver: address
    liquidate_bonus: uint256
    price_impact_multiplier: uint256
    bad_debt_liquidations_allowed: bool

@external
def set_configuration(
    _liquidation_penalty: uint256,
    _trading_fee_safety_module_interest_share_percentage: uint256,
    _fee_config: address,
    _interest_rate_config: address,
    _withdraw_liq_cooldown_seconds: uint256,
    _fee_receiver: address,
    _liquidate_bonus: uint256,
    _price_impact_multiplier: uint256,
    _bad_debt_liquidations_allowed: bool,
):
    assert msg.sender == self.admin, "unauthorized"

    assert _liquidation_penalty <= PERCENTAGE_BASE, "cannot be more than 100%"
    self.liquidation_penalty = _liquidation_penalty

    assert _trading_fee_safety_module_interest_share_percentage <= PERCENTAGE_BASE, "cannot be more than 100%"
    self.safety_module_interest_share_percentage = _trading_fee_safety_module_interest_share_percentage

    assert not _fee_config == empty(address)
    self.fee_config = _fee_config

    assert not _interest_rate_config == empty(address)
    self.interest_rate_config = _interest_rate_config

    assert _withdraw_liq_cooldown_seconds > 0
    self.withdraw_liquidity_cooldown = _withdraw_liq_cooldown_seconds

    assert _fee_receiver != empty(address), "fee receiver cannot be zero address"
    self.protocol_fee_receiver = _fee_receiver

    assert _liquidate_bonus < PERCENTAGE_BASE, "liquidate_bonus cannot be more than 100%"
    self.liquidation_bonus = _liquidate_bonus

    assert _price_impact_multiplier >= 1
    self.price_impact_multiplier = _price_impact_multiplier

    self.bad_debt_liquidations_allowed = _bad_debt_liquidations_allowed

    log ConfigurationUpdated(msg.sender, _liquidation_penalty, _trading_fee_safety_module_interest_share_percentage, _fee_config, _interest_rate_config, _withdraw_liq_cooldown_seconds, _fee_receiver, _liquidate_bonus, _price_impact_multiplier, _bad_debt_liquidations_allowed)




event WhitelistedDexUpdated:
    updated_by: address
    dex: address
    is_whitelisted: bool

@external
def set_is_whitelisted_dex(_dex: address, _whitelisted: bool):
    assert msg.sender == self.admin, "unauthorized"
    self.is_whitelisted_dex[_dex] = _whitelisted

    log WhitelistedDexUpdated(msg.sender, _dex, _whitelisted)

event WhitelistedLiquidatorUpdated:
    updated_by: address
    liquidator: address
    is_whitelisted: bool

@external
def set_is_whitelisted_liquidator(_liquidator: address, _whitelisted: bool):
    assert msg.sender == self.admin, "unauthorized"
    self.is_whitelisted_liquidator[_liquidator] = _whitelisted

    log WhitelistedLiquidatorUpdated(msg.sender, _liquidator, _whitelisted)
