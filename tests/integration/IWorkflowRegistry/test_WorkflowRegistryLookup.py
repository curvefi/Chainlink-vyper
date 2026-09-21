"""Pin the live WorkflowRegistry's answer for unknown workflows: an empty struct, not a revert."""

import pytest
from conftest import WORKFLOW_OWNER

EMPTY_ID = bytes(32)


@pytest.mark.mainnet
def test_lookup_by_id_known_workflow(registry):
    """Positive control: a registered workflow's id resolves to itself, so an empty answer
    below cannot come from a wrong address or a broken decoder."""
    listed = registry.getWorkflowListByOwner(WORKFLOW_OWNER, 0, 1)
    assert len(listed) == 1

    workflow = registry.getWorkflowById(listed[0].workflow_id)
    assert workflow.workflow_id == listed[0].workflow_id
    assert workflow.owner == WORKFLOW_OWNER


@pytest.mark.mainnet
def test_lookup_by_id_unknown_returns_empty(registry):
    """getWorkflowById does not revert for an unregistered id; workflow_id comes back zero."""
    workflow = registry.getWorkflowById(b"\xab" * 32)

    assert workflow.workflow_id == EMPTY_ID
    assert workflow.workflow_name == ""


@pytest.mark.mainnet
def test_lookup_by_name_unknown_returns_empty(registry):
    """getWorkflow does not revert for an unregistered owner/name/tag; workflow_id comes back zero."""
    workflow = registry.getWorkflow(WORKFLOW_OWNER, "no-such-workflow", "no-such-tag")

    assert workflow.workflow_id == EMPTY_ID
