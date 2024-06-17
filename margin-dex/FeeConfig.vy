# @version 0.3.10

###################################################################
#
# @title Unstoppable Margin DEX - Trading Fee Configuration
# @license GNU AGPLv3
# @author unstoppable.ooo
#
# @custom:security-contact team@unstoppable.ooo
#
# @notice
#    This contract is part of the Unstoppable Margin DEX.
#
#    It handles the fees users have to pay to open positions.
#
###################################################################

PERCENTAGE_BASE: constant(uint256) = 100_00 # == 100%

default_fee: public(uint256)
fees: public(HashMap[address, uint256])


admin: public(address)
suggested_admin: public(address)

@external
def __init__(_default_fee: uint256):
    self.admin = msg.sender
    self.default_fee = _default_fee
    

@external
@view
def get_fee_for_account(_account: address, _token_amount: uint256, _token_in: address, _token_out: address) -> uint256:
    if self.fees[_account] != empty(uint256):
        return _token_amount * self.fees[_account] / PERCENTAGE_BASE

    return _token_amount * self.default_fee / PERCENTAGE_BASE


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


event FeeConfigured:
    account: indexed(address)
    fee: uint256

@external
def set_fee_for_account(_account: address, _fee: uint256):
    assert msg.sender == self.admin, "unauthorized"
    assert _account != empty(address), "invalid address"
    self.fees[_account] = _fee
    log FeeConfigured(_account, _fee)

@external
def set_default_fee(_fee: uint256):
    assert msg.sender == self.admin, "unauthorized"
    self.default_fee = _fee
    log FeeConfigured(empty(address), _fee)