# @version 0.3.10

###################################################################
#
# @title Unstoppable Margin DEX - Interest Rate Configuration
# @license GNU AGPLv3
# @author unstoppable.ooo
#
# @custom:security-contact team@unstoppable.ooo
#
# @notice
#    This contract is part of the Unstoppable Margin DEX.
#
#    It handles interest rate calculations depending on utilization
#    rate.
#
###################################################################

FULL_UTILIZATION: constant(uint256) = 100_00_000
FALLBACK_INTEREST_CONFIGURATION: constant(uint256[4]) = [
    3_00_000,
    20_00_000,
    100_00_000,
    80_00_000,
]

PRECISION: constant(uint256) = 10**18

SECONDS_PER_YEAR: constant(uint256) = 365 * 24 * 60 * 60
PERCENTAGE_BASE: constant(uint256) = 100_00 # == 100%
PERCENTAGE_BASE_HIGH_PRECISION: constant(uint256) = 100_00_000  # == 100%

# dynamic interest rates [min, mid, max, kink]
interest_configuration: HashMap[address, uint256[4]]

admin: public(address)
suggested_admin: public(address)

@external
def __init__():
    self.admin = msg.sender


#####################################
#
#             INTEREST
#
#####################################

@external
@view
def interest_rate_by_utilization(_address: address, _utilization_rate: uint256) -> uint256:
    return self._interest_rate_by_utilization(_address, _utilization_rate)

@internal
@view
def _interest_rate_by_utilization(
    _address: address, _utilization_rate: uint256
) -> uint256:
    """
    @notice
        we have two tiers of interest rates that are linearily growing from
        _min_interest_rate to _mid_interest_rate and _mid_interest_rate to
        _max_interest_rate respectively. The switch between both occurs at
        _rate_switch_utilization

        note: the slope of the first line must be lower then the second line, if
        not the contact will revert
    """
    if _utilization_rate < self._rate_switch_utilization(_address):
        return self._dynamic_interest_rate_low_utilization(_address, _utilization_rate)
    else:
        return self._dynamic_interest_rate_high_utilization(_address, _utilization_rate)


@internal
@view
def _dynamic_interest_rate_low_utilization(
    _address: address, _utilization_rate: uint256
) -> uint256:
    # if it's zero we return the min-interest-rate without calculation
    if _utilization_rate == 0:
        return self._min_interest_rate(_address)

    # default line-equation y = mx + d where m is the slope, x is
    # _utilization_rate and d is the min_interest_rate, the staring point at 0
    # utilization thus y = _slope * _utilization_rate -_diff

    # first part of the equation mx
    _additional_rate_through_utilization: uint256 = (
        PRECISION
        * _utilization_rate
        * (self._mid_interest_rate(_address) - self._min_interest_rate(_address))
        / self._rate_switch_utilization(_address)
    )

    # first part of the equation d + mx
    return (
        self._min_interest_rate(_address) * PRECISION
        + _additional_rate_through_utilization
    ) / PRECISION


@internal
@view
def _dynamic_interest_rate_high_utilization(
    _address: address, _utilization_rate: uint256
) -> uint256:
    # if it's smaller switch zero we return the min-interest-rate without
    # calculation
    if _utilization_rate < self._rate_switch_utilization(_address):
        return self._mid_interest_rate(_address)

    # default line-equation y = mx + d where m is _slope, x is _utilization_rate
    # and m  is _diff
    # thus y = _slope * _utilization_rate -_diff
    _slope: uint256 = (
        (self._max_interest_rate(_address) - self._mid_interest_rate(_address))
        * PRECISION
        / (FULL_UTILIZATION - self._rate_switch_utilization(_address))
    )

    _diff: uint256 = (
        _slope * PERCENTAGE_BASE_HIGH_PRECISION
        - self._max_interest_rate(_address) * PRECISION
    )
    _additional_rate_through_utilization: uint256 = _slope * _utilization_rate - _diff

    return _additional_rate_through_utilization / PRECISION


@internal
@view
def _min_interest_rate(_address: address) -> uint256:
    if self.interest_configuration[_address][0] == 0:
        return FALLBACK_INTEREST_CONFIGURATION[0]

    return self.interest_configuration[_address][0]


@internal
@view
def _mid_interest_rate(_address: address) -> uint256:
    if self.interest_configuration[_address][1] == 0:
        return FALLBACK_INTEREST_CONFIGURATION[1]

    return self.interest_configuration[_address][1]


@internal
@view
def _max_interest_rate(_address: address) -> uint256:
    if self.interest_configuration[_address][2] == 0:
        return FALLBACK_INTEREST_CONFIGURATION[2]
    return self.interest_configuration[_address][2]


@internal
@view
def _rate_switch_utilization(_address: address) -> uint256:
    if self.interest_configuration[_address][3] == 0:
        return FALLBACK_INTEREST_CONFIGURATION[3]
    return self.interest_configuration[_address][3]



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
    assert _new_admin != empty(address), "cannot set admin to zero address"
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
    log AdminTransferred(self.admin, prev_admin)


@external
def set_variable_interest_parameters(
    _address: address,
    _min_interest_rate: uint256,
    _mid_interest_rate: uint256,
    _max_interest_rate: uint256,
    _rate_switch_utilization: uint256,
):
    assert msg.sender == self.admin, "unauthorized"

    self.interest_configuration[_address] = [
        _min_interest_rate,
        _mid_interest_rate,
        _max_interest_rate,
        _rate_switch_utilization,
    ]
