"""Test CCIP module _transmit function (requires mainnet fork — calls real ccipSend)."""

import boa
import pytest
from eth_utils import keccak
from boa.contracts.base_evm_contract import BoaError
from boa.contracts.event_decoder import RawLogEntry
from conftest import BASE_CHAIN_SELECTOR, CCIP_RECEIVE_GAS_LIMIT, LINK


def _build_test_message(ccip_module, selector):
    """Build a minimal EVM2AnyMessage to the receiver registered for `selector`."""
    data = boa.util.abi.abi_encode("(uint256,bytes32)", (12345, bytes(32)))
    extra_args = ccip_module.build_extra_args(CCIP_RECEIVE_GAS_LIMIT)
    return ccip_module.build_simple_message(selector, data, extra_args)


def _raw_message(ccip_module, receiver):
    """Hand-built EVM2AnyMessage to any address, bypassing the builder's receiver lookup."""
    data = boa.util.abi.abi_encode("(uint256,bytes32)", (12345, bytes(32)))
    extra_args = ccip_module.build_extra_args(CCIP_RECEIVE_GAS_LIMIT)
    return (boa.util.abi.abi_encode("address", receiver), data, [], "0x" + "00" * 20, extra_args)


def test_transmit_no_receiver_reverts(ccip_module, dev_deployer):
    """_transmit reverts before any router call when the destination has no registered receiver."""
    selector = 111
    receiver = boa.env.generate_address()
    message = _raw_message(ccip_module, receiver)

    # No set_receiver / set_peer for `selector` → getter reverts loudly
    with boa.reverts("No receiver"):
        ccip_module.transmit(selector, message, 0)


def test_transmit_receiver_mismatch_reverts(ccip_module, dev_deployer):
    """_transmit reverts when the message targets an address other than the registered receiver."""
    selector = 111
    registered = boa.env.generate_address()
    other = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module.set_receiver(selector, registered)

    # Message built for `other`, but `registered` is what's configured
    message = _raw_message(ccip_module, other)
    with boa.reverts("Receiver mismatch"):
        ccip_module.transmit(selector, message, 0)


def test_transmit_non_native_fee_token_reverts(ccip_module, dev_deployer):
    """_transmit refuses a message that selects an ERC20 fee token; it can only pay natively."""
    selector = 111
    receiver = boa.env.generate_address()
    with boa.env.prank(dev_deployer):
        ccip_module.set_receiver(selector, receiver)

    message = list(_raw_message(ccip_module, receiver))
    message[3] = LINK
    with boa.reverts("Native fee only"):
        ccip_module.transmit(selector, tuple(message), 0)


@pytest.mark.mainnet
def test_transmit_deducts_fee_and_emits_ccip_event(ccip_module_mainnet, dev_deployer):
    """_transmit calls ccipSend: balance decreases by exactly the fee and the CCIP
    onramp emits CCIPMessageSent with the target chain selector in topics[1]."""
    receiver = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module_mainnet.set_receiver(BASE_CHAIN_SELECTOR, receiver)

    message = _build_test_message(ccip_module_mainnet, BASE_CHAIN_SELECTOR)
    fee = ccip_module_mainnet.quote(BASE_CHAIN_SELECTOR, message)

    boa.env.set_balance(ccip_module_mainnet.address, fee)
    balance_before = boa.env.get_balance(ccip_module_mainnet.address)

    ccip_module_mainnet.transmit(BASE_CHAIN_SELECTOR, message, fee)

    # Capture logs before any getter — view calls reset boa's log buffer
    events = ccip_module_mainnet.get_logs()

    # The CCIP onramp is a forked mainnet contract unknown to boa → RawLogEntry.
    # CCIPMessageSent indexes destChainSelector as topics[1]; WETH logs carry an
    # address in topics[1] (>> uint64 range) so they cannot collide with selectors.
    sent_selectors = [
        e.topics[1] for e in events if isinstance(e, RawLogEntry) and len(e.topics) >= 2
    ]
    assert BASE_CHAIN_SELECTOR in sent_selectors

    assert boa.env.get_balance(ccip_module_mainnet.address) == balance_before - fee


@pytest.mark.mainnet
def test_transmit_returns_message_id_and_actual_fee(ccip_module_mainnet, dev_deployer):
    """_transmit returns the router message id and the actual (live-quoted) fee paid."""
    receiver = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module_mainnet.set_receiver(BASE_CHAIN_SELECTOR, receiver)

    message = _build_test_message(ccip_module_mainnet, BASE_CHAIN_SELECTOR)
    fee = ccip_module_mainnet.quote(BASE_CHAIN_SELECTOR, message)

    boa.env.set_balance(ccip_module_mainnet.address, fee)

    # generous ceiling: max_fee above the live fee
    message_id, paid = ccip_module_mainnet.transmit(BASE_CHAIN_SELECTOR, message, fee * 2)
    assert paid == fee
    assert message_id != bytes(32)


@pytest.mark.mainnet
def test_transmit_reverts_when_max_fee_below_live(ccip_module_mainnet, dev_deployer):
    """_transmit reverts with "Too high fees" when the live fee exceeds max_fee (never overpays)."""
    receiver = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module_mainnet.set_receiver(BASE_CHAIN_SELECTOR, receiver)

    message = _build_test_message(ccip_module_mainnet, BASE_CHAIN_SELECTOR)
    fee = ccip_module_mainnet.quote(BASE_CHAIN_SELECTOR, message)

    boa.env.set_balance(ccip_module_mainnet.address, fee)

    with boa.reverts("Too high fees"):
        ccip_module_mainnet.transmit(BASE_CHAIN_SELECTOR, message, fee - 1)


@pytest.mark.mainnet
def test_transmit_insufficient_balance_reverts(ccip_module_mainnet, dev_deployer):
    """_transmit reverts when the contract balance is less than the requested fee."""
    receiver = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module_mainnet.set_receiver(BASE_CHAIN_SELECTOR, receiver)

    message = _build_test_message(ccip_module_mainnet, BASE_CHAIN_SELECTOR)
    fee = ccip_module_mainnet.quote(BASE_CHAIN_SELECTOR, message)

    boa.env.set_balance(ccip_module_mainnet.address, fee - 1)

    with boa.reverts():
        ccip_module_mainnet.transmit(BASE_CHAIN_SELECTOR, message, fee)


@pytest.mark.mainnet
def test_transmit_fake_selector_reverts(ccip_module_mainnet, dev_deployer):
    """_transmit reverts when the chain selector is not recognized by the real router."""
    fake_selector = 111
    receiver = boa.env.generate_address()

    with boa.env.prank(dev_deployer):
        ccip_module_mainnet.set_receiver(fake_selector, receiver)

    data = boa.util.abi.abi_encode("(uint256,bytes32)", (12345, bytes(32)))
    extra_args = ccip_module_mainnet.build_extra_args(CCIP_RECEIVE_GAS_LIMIT)
    message = ccip_module_mainnet.build_simple_message(fake_selector, data, extra_args)

    boa.env.set_balance(ccip_module_mainnet.address, 10**18)

    with boa.reverts():
        ccip_module_mainnet.transmit(fake_selector, message, 10**14)


# ─── _try_transmit ───────────────────────────────────────────────────────────


@pytest.mark.mainnet
def test_try_transmit_selectors_match_the_router_interface(ccip_module_mainnet, dev_deployer):
    """_try_transmit calls the router by hand, so its selectors must match the typed interface.

    Vyper takes method_id only as a literal string, and a stale one would quietly make every
    destination look unreachable. The live router answers both paths here, so they must agree.
    """
    receiver = boa.env.generate_address()
    with boa.env.prank(dev_deployer):
        ccip_module_mainnet.set_receiver(BASE_CHAIN_SELECTOR, receiver)
    message = _build_test_message(ccip_module_mainnet, BASE_CHAIN_SELECTOR)

    # the hand-built getFee must price the message exactly as the interface does
    fee = ccip_module_mainnet.quote(BASE_CHAIN_SELECTOR, message)
    boa.env.set_balance(ccip_module_mainnet.address, fee)
    sent, message_id, paid = ccip_module_mainnet.try_transmit(BASE_CHAIN_SELECTOR, message, fee)

    assert sent is True
    assert paid == fee
    assert message_id != bytes(32)

    get_fee_id, ccip_send_id = ccip_module_mainnet.method_ids()
    assert (
        get_fee_id == keccak(b"getFee(uint64,(bytes,bytes,(address,uint256)[],address,bytes))")[:4]
    )
    assert (
        ccip_send_id
        == keccak(b"ccipSend(uint64,(bytes,bytes,(address,uint256)[],address,bytes))")[:4]
    )


@pytest.mark.mainnet
def test_try_transmit_reports_what_the_router_refuses(ccip_module_mainnet, dev_deployer):
    """An unsupported chain, a fee over the cap and a fee over the balance are reported, not raised."""
    receiver = boa.env.generate_address()
    fake_selector = 111
    with boa.env.prank(dev_deployer):
        ccip_module_mainnet.set_receiver(BASE_CHAIN_SELECTOR, receiver)
        ccip_module_mainnet.set_receiver(fake_selector, receiver)

    message = _build_test_message(ccip_module_mainnet, BASE_CHAIN_SELECTOR)
    fee = ccip_module_mainnet.quote(BASE_CHAIN_SELECTOR, message)
    boa.env.set_balance(ccip_module_mainnet.address, fee)

    # the router does not serve this chain, so even its quote reverts
    unsupported = _build_test_message(ccip_module_mainnet, fake_selector)
    assert ccip_module_mainnet.try_transmit(fake_selector, unsupported, fee)[0] is False
    # cap below the live fee
    assert ccip_module_mainnet.try_transmit(BASE_CHAIN_SELECTOR, message, fee - 1)[0] is False
    # balance below the live fee
    boa.env.set_balance(ccip_module_mainnet.address, fee - 1)
    assert ccip_module_mainnet.try_transmit(BASE_CHAIN_SELECTOR, message, fee)[0] is False


@pytest.mark.mainnet
def test_try_transmit_never_reports_a_starved_send_as_a_refusal(ccip_module_mainnet, dev_deployer):
    """Whoever submits the transaction picks its gas. A valid destination starved of gas must revert,
    so the delivery stays retryable, rather than come back False and be skipped as a refusal."""
    receiver = boa.env.generate_address()
    with boa.env.prank(dev_deployer):
        ccip_module_mainnet.set_receiver(BASE_CHAIN_SELECTOR, receiver)
    message = _build_test_message(ccip_module_mainnet, BASE_CHAIN_SELECTOR)
    fee = ccip_module_mainnet.quote(BASE_CHAIN_SELECTOR, message)

    outcomes = set()
    for gas in range(60_000, 400_000, 5_000):
        boa.env.set_balance(ccip_module_mainnet.address, fee)
        try:
            sent = ccip_module_mainnet.try_transmit(BASE_CHAIN_SELECTOR, message, fee, gas=gas)[0]
        except BoaError:
            outcomes.add("reverted")
            continue
        assert sent is True, f"a valid destination came back as a refusal at gas={gas}"
        outcomes.add("sent")

    # the sweep must actually cross from starved to sufficient, or it proves nothing
    assert outcomes == {"reverted", "sent"}
