# @version 0.3.10

from vyper.interfaces import ERC20

# struct ExactInputSingleParams {
#         address tokenIn;
#         address tokenOut;
#         uint24 fee;
#         address recipient;
#         uint256 deadline;
#         uint256 amountIn;
#         uint256 amountOutMinimum;
#         uint160 sqrtPriceLimitX96;
#     }
struct ExactInputSingleParams:
    tokenIn: address
    tokenOut: address
    fee: uint24
    recipient: address
    deadline: uint256
    amountIn: uint256
    amountOutMinimum: uint256
    sqrtPriceLimitX96: uint160

# struct ExactInputParams {
#     bytes path;
#     address recipient;
#     uint256 deadline;
#     uint256 amountIn;
#     uint256 amountOutMinimum;
# }
struct ExactInputParams:
    path: Bytes[66]
    recipient: address
    deadline: uint256
    amountIn: uint256
    amountOutMinimum: uint256

# struct ExactOutputSingleParams {
#         address tokenIn;
#         address tokenOut;
#         uint24 fee;
#         address recipient;
#         uint256 deadline;
#         uint256 amountOut;
#         uint256 amountInMaximum;
#         uint160 sqrtPriceLimitX96;
#     }
struct ExactOutputSingleParams:
    tokenIn: address
    tokenOut: address
    fee: uint24
    recipient: address
    deadline: uint256
    amountOut: uint256
    amountInMaximum: uint256
    sqrtPriceLimitX96: uint160

# struct ExactOutputParams {
#         bytes path;
#         address recipient;
#         uint256 deadline;
#         uint256 amountOut;
#         uint256 amountInMaximum;
#     }
struct ExactOutputParams:
    path: Bytes[66]
    recipient: address
    deadline: uint256
    amountOut: uint256
    amountInMaximum: uint256


# function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
interface UniswapV3SwapRouter:
    def exactInputSingle(_params: ExactInputSingleParams) -> uint256: payable
    def exactInput(_params: ExactInputParams) -> uint256: payable
    def exactOutputSingle(_params: ExactOutputSingleParams) -> uint256: payable
    def exactOutput(_params: ExactOutputParams) -> uint256: payable

UNISWAP_ROUTER: constant(address) = 0xE592427A0AEce92De3Edee1F18E0157C05861564

# token_in -> token_out -> fee
direct_route: public(HashMap[address, HashMap[address, uint24]])
paths: public(HashMap[address, HashMap[address, Bytes[66]]])

admin: public(address)
suggested_admin: public(address)


@nonpayable
@external
def __init__():
    self.admin = msg.sender


event SwapRouterSwap:
    origin: indexed(address)
    routed_to: address
    token_in: address
    amount_in: uint256
    token_out: address
    amount_out: uint256

@external
def swap(
    _token_in: address,
    _token_out: address,
    _amount_in: uint256,
    _min_amount_out: uint256,
) -> uint256:
    ERC20(_token_in).transferFrom(msg.sender, self, _amount_in)
    ERC20(_token_in).approve(UNISWAP_ROUTER, _amount_in)

    amount_out: uint256 = 0

    if self.direct_route[_token_in][_token_out] != 0:
        amount_out = self._direct_swap(_token_in, _token_out, _amount_in, _min_amount_out)
    else:
        amount_out = self._multi_hop_swap(_token_in, _token_out, _amount_in, _min_amount_out)

    log SwapRouterSwap(msg.sender, UNISWAP_ROUTER, _token_in, _amount_in, _token_out, amount_out)

    return amount_out

@external
def swap_exact_out(
    _token_in: address,
    _token_out: address,
    _amount_out: uint256,
    _max_amount_in: uint256,
) -> uint256:
    ERC20(_token_in).transferFrom(msg.sender, self, _max_amount_in)
    ERC20(_token_in).approve(UNISWAP_ROUTER, _max_amount_in)

    actual_amount_in: uint256 = 0

    if self.direct_route[_token_in][_token_out] != 0:
        actual_amount_in = self._direct_swap_exact_out(_token_in, _token_out, _amount_out, _max_amount_in)
    else:
        actual_amount_in = self._multi_hop_swap_exact_out(_token_in, _token_out, _amount_out, _max_amount_in)

    if actual_amount_in < _max_amount_in:
        ERC20(_token_in).transfer(msg.sender, _max_amount_in-actual_amount_in)

    log SwapRouterSwap(msg.sender, UNISWAP_ROUTER, _token_in, actual_amount_in, _token_out, _amount_out)

    return actual_amount_in


@internal
def _direct_swap(
    _token_in: address,
    _token_out: address,
    _amount_in: uint256,
    _min_amount_out: uint256,
) -> uint256:
    fee: uint24 = self.direct_route[_token_in][_token_out]
    assert fee != 0, "no direct route"

    params: ExactInputSingleParams = ExactInputSingleParams(
        {
            tokenIn: _token_in,
            tokenOut: _token_out,
            fee: fee,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: _amount_in,
            amountOutMinimum: _min_amount_out,
            sqrtPriceLimitX96: 0,
        }
    )
    return UniswapV3SwapRouter(UNISWAP_ROUTER).exactInputSingle(params)


@internal
def _multi_hop_swap(
    _token_in: address,
    _token_out: address,
    _amount_in: uint256,
    _min_amount_out: uint256,
) -> uint256:
    path: Bytes[66] = self.paths[_token_in][_token_out]
    assert path != empty(Bytes[66]), "no path configured"

    uni_params: ExactInputParams = ExactInputParams(
        {
            path: path,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: _amount_in,
            amountOutMinimum: _min_amount_out,
        }
    )
    return UniswapV3SwapRouter(UNISWAP_ROUTER).exactInput(uni_params)


@internal
def _direct_swap_exact_out(
    _token_in: address,
    _token_out: address,
    _amount_out: uint256,
    _max_amount_in: uint256,
) -> uint256:
    fee: uint24 = self.direct_route[_token_in][_token_out]
    assert fee != 0, "no direct route"

    params: ExactOutputSingleParams = ExactOutputSingleParams(
        {
            tokenIn: _token_in,
            tokenOut: _token_out,
            fee: fee,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountOut: _amount_out,
            amountInMaximum: _max_amount_in,
            sqrtPriceLimitX96: 0,
        }
    )
    return UniswapV3SwapRouter(UNISWAP_ROUTER).exactOutputSingle(params)


@internal
def _multi_hop_swap_exact_out(
    _token_in: address,
    _token_out: address,
    _amount_out: uint256,
    _max_amount_in: uint256,
) -> uint256:
    path: Bytes[66] = self.paths[_token_out][_token_in]
    assert path != empty(Bytes[66]), "no path configured"

    uni_params: ExactOutputParams = ExactOutputParams(
        {
            path: path,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountOut: _amount_out,
            amountInMaximum: _max_amount_in,
        }
    )
    return UniswapV3SwapRouter(UNISWAP_ROUTER).exactOutput(uni_params)


event RouteAdded:
    admin: address
    token_1: address
    token_2: address
    is_direct_route: bool
    fee: uint24
    path_t1_to_t2: Bytes[66]
    path_t2_to_t1: Bytes[66]

@external
def add_direct_route(_token1: address, _token2: address, _fee: uint24):
    assert msg.sender == self.admin, "unauthorized"
    self.direct_route[_token1][_token2] = _fee
    self.direct_route[_token2][_token1] = _fee

    log RouteAdded(msg.sender, _token1, _token2, True, _fee, empty(Bytes[66]), empty(Bytes[66]))


@external
def add_path(_token1: address, _token2: address, _path_t1_to_t2: Bytes[66], _path_t2_to_t1: Bytes[66]):
    assert msg.sender == self.admin, "unauthorized"
    self.paths[_token1][_token2] = _path_t1_to_t2
    self.paths[_token2][_token1] = _path_t2_to_t1

    log RouteAdded(msg.sender, _token1, _token2, False, 0, _path_t1_to_t2, _path_t2_to_t1)


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