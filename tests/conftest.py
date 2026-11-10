import os

import boa
import pytest

BOA_CACHE = True


@pytest.fixture(scope="session")
def drpc_api_key():
    api_key = os.getenv("DRPC_API_KEY")
    assert api_key is not None, "DRPC_API_KEY environment variable not set"
    return api_key


@pytest.fixture()
def dev_deployer():
    return boa.env.generate_address()


@pytest.fixture(scope="session")
def rpc_url(drpc_api_key):
    """Default fork target: Ethereum mainnet (CCIP router lives here)."""
    return f"https://lb.drpc.org/ogrpc?network=ethereum&dkey={drpc_api_key}"


@pytest.fixture()
def forked_env(rpc_url):
    """Automatically fork each test with the specified chain."""
    block_to_fork = "latest"
    with boa.swap_env(boa.Env()):
        if BOA_CACHE:
            boa.fork(url=rpc_url, block_identifier=block_to_fork)
        else:
            boa.fork(url=rpc_url, block_identifier=block_to_fork, cache_file=None)
        boa.env.enable_fast_mode()
        yield


_INTERFACE_PROBER = """
interface_id: bytes4
answer: public(bool)

@deploy
def __init__(_interface_id: bytes4):
    self.interface_id = _interface_id

@external
@payable
def __default__():
    # asks the caller the way ERC165Checker does: a 30k-gas staticcall
    ok: bool = False
    out: Bytes[32] = b""
    ok, out = raw_call(
        msg.sender,
        abi_encode(self.interface_id, method_id=method_id("supportsInterface(bytes4)")),
        max_outsize=32,
        gas=30_000,
        is_static_call=True,
        revert_on_failure=False,
    )
    if ok and len(out) == 32:
        self.answer = abi_decode(out, bool)
"""


@pytest.fixture()
def interface_prober():
    """Deploys a contract that, when called, records whether its caller supports an interface."""
    return lambda interface_id: boa.loads(_INTERFACE_PROBER, interface_id)
