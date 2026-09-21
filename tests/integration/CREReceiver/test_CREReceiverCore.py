"""Test CREReceiver module initialization and interface support."""

from pathlib import Path

from conftest import EMPTY_ADDRESS
from vyper.ast import nodes, parse_to_ast

SRC = Path(__file__).parents[3] / "src"


def _constants(filename):
    module = parse_to_ast((SRC / filename).read_text())
    return {
        decl.target.id: decl.value.value
        for decl in module.get_children(nodes.VariableDecl)
        if decl.is_constant and isinstance(decl.value, nodes.Int)
    }


def test_initial_state(cre_receiver, dev_deployer):
    """All permission fields are unset (zero) after deployment; deployer is the owner."""
    assert cre_receiver.owner() == dev_deployer
    assert cre_receiver.forwarder_address() == EMPTY_ADDRESS
    assert cre_receiver.expected_author() == EMPTY_ADDRESS
    assert cre_receiver.expected_workflow_name() == bytes(10)
    assert cre_receiver.expected_workflow_id() == bytes(32)


def test_supports_interface(cre_receiver):
    """supportsInterface returns True for ERC165 and IReceiver; False for unknown."""
    assert cre_receiver.supportsInterface(bytes.fromhex("01ffc9a7")) is True  # ERC165
    assert cre_receiver.supportsInterface(bytes.fromhex("805f2132")) is True  # IReceiver
    assert cre_receiver.supportsInterface(bytes.fromhex("deadbeef")) is False


def test_interface_limits_match_module():
    """IReceiver.vyi duplicates CREReceiver's size bounds; a vyper module cannot read .vyi
    constants, so the two copies are kept in sync here."""
    interface_limits = _constants("IReceiver.vyi")
    module_limits = _constants("CREReceiver.vy")

    assert interface_limits.keys() == {"MAX_METADATA_SIZE", "MAX_REPORT_SIZE"}
    for name, value in interface_limits.items():
        assert module_limits[name] == value, name
