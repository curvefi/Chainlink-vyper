# Chainlink Vyper Module

Vyper interfaces and modules for integrating with Chainlink's CRE (Chainlink Runtime
Environment) and CCIP (Cross-Chain Interoperability Protocol), built as a standalone
package. Curve's Blockhash Oracle is powered by this module
(https://github.com/curvefi/blockhash-oracle).

## Overview

The module provides:
- `CCIP` — sending and receiving cross-chain messages via a CCIP router (fee quoting,
  peer management, message transmission/receipt).
- `CREReceiver` — an abstract, permissioned receiver for Chainlink CRE workflow reports
  (`onReport`), with optional checks on forwarder, workflow author, name, and ID.
- `IReceiver` — the `onReport` interface implemented by CRE report receivers.
- `IWorkflowRegistry` — a read-only interface for the CRE `WorkflowRegistry` (always
  deployed on Ethereum mainnet) used to resolve a workflow's ID on-chain.

## Security

Always ensure proper peer/forwarder setup and ownership management when deploying. Code
has not been audited yet and probably contains bugs.

## Development

Requirements:
- Python 3.12+
- Vyper 0.4.3

Testing:
```bash
# Setup virtual environment
uv venv
uv sync
source .venv/bin/activate

# Run all tests
pytest tests/
```

Some tests (`@pytest.mark.mainnet`) fork Ethereum mainnet against a real CCIP router and
require a `DRPC_API_KEY` environment variable.

## Example Use

`examples/ReactorConsumer.vy` shows how to build a CRE report consumer on top of the
`CREReceiver` module: it validates the report via `CREReceiver._on_report`, then decodes
and acts on the payload (flagging an address). Use it as a template for wiring up your
own `onReport` handler.
