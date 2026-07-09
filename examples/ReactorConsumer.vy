# pragma version 0.4.3
# pragma optimize gas
# pragma nonreentrancy on

"""
@title ReactorConsumer

@notice Receives CRE reports and takes action (e.g., flag an address).
A monitored contract emits LargeTransfer events; CRE workflow
checks off-chain data and writes back a flagging action.

@license Copyright (c) Curve.Fi, 2026 - all rights reserved

@author curve.fi

@custom:security security@curve.fi
"""


################################################################
#                           INTERFACES                         #
################################################################

from ..src import IReceiver

implements: IReceiver


################################################################
#                            MODULES                           #
################################################################

# Import ownership management
from snekmate.auth import ownable

initializes: ownable
exports: (
    ownable.owner,
    ownable.transfer_ownership,
    ownable.renounce_ownership,
)

# Import CREReceiver module for cross-chain messaging
from ..src import CREReceiver  # main module

initializes: CREReceiver[ownable := ownable]
exports: CREReceiver.__interface__


################################################################
#                            STORAGE                           #
################################################################

flagged_addresses: public(HashMap[address, bool])
total_flags: public(uint256)


################################################################
#                            EVENTS                            #
################################################################

event AddressFlagged:
    target: indexed(address)
    reason: String[128]
    timestamp: uint256

event ActionTaken:
    action_type: indexed(uint8)
    target: indexed(address)
    timestamp: uint256


################################################################
#                          CONSTRUCTOR                         #
################################################################

@deploy
def __init__(
    _forwarder_address: address,
):
    ownable.__init__()
    ownable._transfer_ownership(tx.origin)  # origin to enable createx deployment

    CREReceiver.__init__(_forwarder_address)


################################################################
#                     EXTERNAL FUNCTIONS                       #
################################################################

@external
@payable
def onReport(metadata: Bytes[CREReceiver.MAX_METADATA_SIZE], report: Bytes[CREReceiver.MAX_REPORT_SIZE]):
    """
    @notice Called by CRE Forwarder via CREReceiver after metadata validation
    @param report ABI-encoded (uint8 actionType, address target, string reason)
    """

    # Verify message source
    CREReceiver._on_report(metadata, report)

    action_type: uint8 = 0
    target: address = empty(address)
    reason: String[128] = ""
    action_type, target, reason = abi_decode(report,(uint8, address, String[128]))

    if action_type == 1:
        self.flagged_addresses[target] = True
        self.total_flags+=1
        log AddressFlagged(target=target, reason=reason, timestamp=block.timestamp)

    log ActionTaken(action_type=action_type, target=target, timestamp=block.timestamp)
