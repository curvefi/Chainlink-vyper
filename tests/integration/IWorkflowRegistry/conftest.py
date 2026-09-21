import os

import boa
import pytest

# CRE WorkflowRegistry, always on Ethereum mainnet
WORKFLOW_REGISTRY = "0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5"

# Curve's workflow owner, known to have registered workflows
WORKFLOW_OWNER = "0x7589D6DADA352B798809278e5A0F8606b6088952"


@pytest.fixture()
def rpc_url(drpc_api_key):
    """Override parent conftest's rpc_url: always fork Ethereum mainnet.

    MAINNET_FORK_RPC overrides the endpoint (useful when the DRPC free tier throttles).
    """
    override = os.getenv("MAINNET_FORK_RPC")
    if override:
        return override
    return f"https://lb.drpc.org/ogrpc?network=ethereum&dkey={drpc_api_key}"


@pytest.fixture()
def registry(forked_env):
    return boa.load_vyi("src/IWorkflowRegistry.vyi").at(WORKFLOW_REGISTRY)
