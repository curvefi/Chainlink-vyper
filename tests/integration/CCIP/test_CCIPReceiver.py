"""Test CCIP module inbound path: _ccipReceive access control and peer validation."""

import boa
from conftest import CCIP_ROUTER, build_any2evm_message


def test_ccip_receive_only_router(ccip_module, dev_deployer):
    """ccipReceive rejects any caller that is not the configured router."""
    selector = 111
    peer = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module.set_peer(selector, peer)

    message = build_any2evm_message(selector, peer)
    stranger = boa.env.generate_address()

    with boa.env.prank(stranger):
        with boa.reverts("Only router"):
            ccip_module.ccipReceive(message)


def test_ccip_receive_rejects_unregistered_sender(ccip_module, dev_deployer):
    """ccipReceive rejects a sender address that doesn't match the registered peer."""
    selector = 111
    peer = boa.env.generate_address()
    impostor = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module.set_peer(selector, peer)

    message = build_any2evm_message(selector, impostor)

    with boa.env.prank(CCIP_ROUTER):
        with boa.reverts("Invalid sender"):
            ccip_module.ccipReceive(message)


def test_ccip_receive_rejects_unregistered_chain(ccip_module):
    """ccipReceive rejects messages from chains with no registered sender (fails loudly)."""
    unregistered_selector = 999
    any_sender = boa.env.generate_address()

    message = build_any2evm_message(unregistered_selector, any_sender)

    with boa.env.prank(CCIP_ROUTER):
        with boa.reverts("No sender"):
            ccip_module.ccipReceive(message)


def test_ccip_receive_valid_message(ccip_module, dev_deployer):
    """Valid message from registered router and peer does not revert."""
    selector = 111
    peer = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module.set_peer(selector, peer)

    message = build_any2evm_message(selector, peer)

    with boa.env.prank(CCIP_ROUTER):
        ccip_module.ccipReceive(message)  # must not revert


def test_ccip_receive_max_data_size(ccip_module, dev_deployer):
    """Inbound data up to MAX_DATA_SIZE (2048) is accepted; one byte over is rejected at decode."""
    selector = 111
    peer = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module.set_peer(selector, peer)

    with boa.env.prank(CCIP_ROUTER):
        ccip_module.ccipReceive(build_any2evm_message(selector, peer, data=b"\x11" * 2048))
        with boa.reverts():
            ccip_module.ccipReceive(build_any2evm_message(selector, peer, data=b"\x11" * 2049))


def test_ccip_receive_token_amounts_bound(ccip_module, dev_deployer):
    """One token amount decodes fine; two exceed the DynArray bound (CCIP allows max 1 token/message)."""
    selector = 111
    peer = boa.env.generate_address()
    token = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module.set_peer(selector, peer)

    one_token = build_any2evm_message(selector, peer)[:4] + ([(token, 100)],)
    two_tokens = build_any2evm_message(selector, peer)[:4] + ([(token, 100), (token, 200)],)

    with boa.env.prank(CCIP_ROUTER):
        ccip_module.ccipReceive(one_token)
        with boa.reverts():
            ccip_module.ccipReceive(two_tokens)
