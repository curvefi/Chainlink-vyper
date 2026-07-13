# pragma version 0.4.3
# pragma optimize gas
"""
@title CCIP - Cross-chain messaging via a CCIP router

@notice Sends and receives cross-chain messages: fee quoting, peer management,
message building and transmission/receipt.

@dev Inbound messages are only accepted from the router and a registered
per-selector sender; outbound messages only go to a registered receiver.
Peers are configured via set_peer (symmetric) or set_receiver/set_sender
(asymmetric).

@license Copyright (c) Curve.Fi, 2026 - all rights reserved

@author curve.fi

@custom:security security@curve.fi
"""

################################################################
#                           INTERFACES                         #
################################################################

# Import ownership management
from snekmate.auth import ownable

uses: ownable

# https://docs.chain.link/ccip/api-reference/evm/v1.6.0/i-router-client
interface Router:
    # @param destinationChainSelector The destination chainSelector.
    # @param message The cross-chain CCIP message including data and/or tokens.
    # @return fee returns execution fee for the message.
    # delivery to destination chain, denominated in the feeToken specified in the message.
    # @dev Reverts with appropriate reason upon invalid message.
    def getFee(_destinationChainSelector: uint64, _message: EVM2AnyMessage) -> uint256: view

    # @notice Request a message to be sent to the destination chain.
    # @param destinationChainSelector The destination chain ID.
    # @param message The cross-chain CCIP message including data and/or tokens.
    # @return messageId The message ID.
    # @dev Note if msg.value is larger than the required fee (from getFee) we accept.
    # the overpayment with no refund.
    # @dev Reverts with appropriate reason upon invalid message.
    def ccipSend(_destinationChainSelector: uint64, _message: EVM2AnyMessage) -> bytes32: payable

    # @notice Checks if the given chain ID is supported for sending/receiving.
    # @param destChainSelector The chain to check.
    # @return supported is true if it is supported, false if not.
    def isChainSupported(_destinationChainSelector: uint64) -> bool: view


################################################################
#                            EVENTS                            #
################################################################


event SetRouter:
    router: address

event SetReceiver:
    destination_chain_selector: indexed(uint64)
    receiver: address


################################################################
#                           CONSTANTS                          #
################################################################


GENERIC_EXTRA_ARGS_V2_TAG: constant(bytes4) = 0x181dcf10
# CCIP protocol allows up to 30 KB
# https://docs.chain.link/ccip/service-limits/evm
MAX_DATA_SIZE: constant(uint256) = 2048

# @dev Static list of supported ERC165 interface ids
SUPPORTED_INTERFACES: constant(bytes4[2]) = [
    # ERC165 interface ID of ERC165
    0x01ffc9a7,
    # ERC165 interface ID of CCIPReceiver
    0x85572ffb,
]


################################################################
#                            STORAGE                           #
################################################################


# https://docs.chain.link/ccip/api-reference/evm/v1.6.0/client#evmtokenamount
struct EVMTokenAmount:
    token: address
    amount: uint256

# https://docs.chain.link/ccip/api-reference/evm/v1.6.0/client#evm2anymessage
struct EVM2AnyMessage:
    receiver: Bytes[32]
    data: Bytes[MAX_DATA_SIZE]
    # Max 1 distinct token per message: https://docs.chain.link/ccip/service-limits/evm
    token_amounts: DynArray[EVMTokenAmount, 1]
    fee_token: address
    extra_args: Bytes[68]

struct Any2EVMMessage:
    message_id: bytes32
    source_chain_selector: uint64
    sender: Bytes[32]
    data: Bytes[MAX_DATA_SIZE]
    # Max 1 distinct token per message: https://docs.chain.link/ccip/service-limits/evm
    token_amounts: DynArray[EVMTokenAmount, 1]

struct GenericExtraArgsV2:
    gas_limit: uint256
    allow_out_of_order_execution: bool

event SetSender:
    source_chain_selector: indexed(uint64)
    sender: address


router: public(address)
selector_to_receiver: public(HashMap[uint64, address])
selector_to_sender: public(HashMap[uint64, address])


################################################################
#                          CONSTRUCTOR                         #
################################################################


@deploy
def __init__(_ccip_router: address):
    self.router = _ccip_router
    log SetRouter(router=_ccip_router)


################################################################
#                      OWNER FUNCTIONS                         #
################################################################


@external
def set_router(_ccip_router: address):
    """
    @notice Set the CCIP router
    @dev Necessary for any potential upgrades to the router tech
    """
    ownable._check_owner()

    self.router = _ccip_router
    log SetRouter(router=_ccip_router)


@external
def set_peer(_chain_selector: uint64, _peer: address):
    """
    @notice Set the receiver and the sender for cross chain transactions
    @param _chain_selector The unique CCIP destination chain selector
    @param _peer The address on the destination chain to transmit messages to and/or receive from
    """
    ownable._check_owner()

    self._set_peer(_chain_selector, _peer)


@external
def set_receiver(_chain_selector: uint64, _receiver: address):
    """
    @notice Set only the outbound receiver for a destination chain
    @dev Use for asymmetric trust (e.g. send-only peer where the return path differs)
    @param _chain_selector The unique CCIP destination chain selector
    @param _receiver The address on the destination chain to transmit messages to
    """
    ownable._check_owner()

    self._set_receiver(_chain_selector, _receiver)


@external
def set_sender(_chain_selector: uint64, _sender: address):
    """
    @notice Set only the inbound trusted sender for a source chain
    @dev Use for asymmetric trust (e.g. receive-only peer that this contract never sends to)
    @param _chain_selector The unique CCIP source chain selector
    @param _sender The address on the source chain to accept messages from
    """
    ownable._check_owner()

    self._set_sender(_chain_selector, _sender)


################################################################
#                     INTERNAL FUNCTIONS                       #
################################################################


@payable
@internal
def _transmit(
    _destination_chain_selector: uint64,
    _message: EVM2AnyMessage,
    _fee: uint256
    ):
    """
    @dev See https://docs.chain.link/ccip/supported-networks/mainnet for chain selectors
    """
    # Only transmit to a registered receiver, and only if the message targets it
    receiver: address = self._get_receiver_or_revert(_destination_chain_selector)
    assert abi_decode(_message.receiver, address) == receiver, "Receiver mismatch"

    extcall Router(self.router).ccipSend(_destination_chain_selector, _message, value=_fee)


@view
@internal
def _quote(_destination_chain_selector: uint64, message: EVM2AnyMessage) -> uint256:
    if not staticcall Router(self.router).isChainSupported(_destination_chain_selector):
        return 0
    return staticcall Router(self.router).getFee(
        _destination_chain_selector,
        message
    )


@internal
@pure
def build_extra_args(gas_limit: uint256) -> Bytes[68]:
    extra_args: Bytes[68] = abi_encode(
        GenericExtraArgsV2(gas_limit=gas_limit, allow_out_of_order_execution=True),
        method_id=GENERIC_EXTRA_ARGS_V2_TAG
    )
    return extra_args



@internal
@pure
def build_simple_message(receiver: address, data: Bytes[MAX_DATA_SIZE], extra_args: Bytes[68]) -> EVM2AnyMessage:
    message: EVM2AnyMessage = EVM2AnyMessage(
            receiver=abi_encode(receiver),
            data=data,
            token_amounts=empty(DynArray[EVMTokenAmount, 1]),
            fee_token=empty(address),
            extra_args=extra_args
        )
    return message


@internal
def _set_receiver(_destination_chain_selector: uint64, _receiver: address):
    """
    @notice Set the receiver for cross chain transactions
    @param _destination_chain_selector The unique CCIP destination chain selector
    @param _receiver The address on the destination chain to transmit messages to
    """

    self.selector_to_receiver[_destination_chain_selector] = _receiver
    log SetReceiver(destination_chain_selector=_destination_chain_selector, receiver=_receiver)


@internal
def _set_sender(_source_chain_selector: uint64, _sender: address):
    """
    @notice Set the sender for cross chain transactions
    @param _source_chain_selector The unique CCIP sorce chain selector
    @param _sender The address on the source chain to receive messages from
    """

    self.selector_to_sender[_source_chain_selector] = _sender
    log SetSender(source_chain_selector=_source_chain_selector, sender=_sender)


@internal
def _set_peer(_chain_selector: uint64, _peer: address):
    """
    @notice Set the receiver and the sender for cross chain transactions
    @param _chain_selector The unique CCIP destination chain selector
    @param _peer The address on the destination chain to transmit messages to and/or receive from
    """

    self._set_sender(_chain_selector, _peer)
    self._set_receiver(_chain_selector, _peer)


@view
@internal
def _get_receiver_or_revert(_destination_chain_selector: uint64) -> address:
    """
    @notice Get the outbound receiver for a destination chain; reverts if unset.
    @dev Safe default for senders that must fail loudly on an unconfigured chain.
    @param _destination_chain_selector The unique CCIP destination chain selector
    @return receiver The trusted receiver address for the destination chain
    """
    receiver: address = self.selector_to_receiver[_destination_chain_selector]
    assert receiver != empty(address), "No receiver"
    return receiver


@view
@internal
def _get_sender_or_revert(_source_chain_selector: uint64) -> address:
    """
    @notice Get the inbound trusted sender for a source chain; reverts if unset.
    @dev Safe default for receivers that must fail loudly on an unconfigured chain.
    @param _source_chain_selector The unique CCIP source chain selector
    @return sender The trusted sender address for the source chain
    """
    sender: address = self.selector_to_sender[_source_chain_selector]
    assert sender != empty(address), "No sender"
    return sender


@internal
def _ccipReceive(_message: Any2EVMMessage):
    assert msg.sender == self.router, "Only router"
    # Verify that the message comes from the registered trusted sender
    sender: address = self._get_sender_or_revert(_message.source_chain_selector)
    assert sender == abi_decode(_message.sender, address), "Invalid sender"


################################################################
#                     EXTERNAL FUNCTIONS                       #
################################################################


@view
@external
def supportsInterface(_interface_id: bytes4) -> bool:
    return _interface_id in SUPPORTED_INTERFACES
