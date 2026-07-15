# pragma version 0.4.3
# pragma optimize gas
"""
@title CCIP - Cross-chain messaging via a CCIP router

@notice Sends and receives cross-chain messages: fee quoting, peer management,
message building and transmission/receipt.

@dev Profile: CCIP EVM v1.6.1, EVM-to-EVM, Receiver V1, GenericExtraArgsV2.
Inbound messages are only accepted from the router and a registered
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

# https://docs.chain.link/ccip/api-reference/evm/v1.6.1/i-router-client
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

event CCIPSecurityWarning:
    message: String[64]


################################################################
#                           CONSTANTS                          #
################################################################


GENERIC_EXTRA_ARGS_V2_TAG: constant(bytes4) = 0x181dcf10

# This library's compile-time payload cap. CCIP itself allows up to 30 KB
# (https://docs.chain.link/ccip/service-limits/evm); 2048 is a deliberately narrower limit here.
MAX_DATA_SIZE: constant(uint256) = 2048

# ABI-bound sizes used by the message structs and builders
MAX_TOKENS_PER_MESSAGE: constant(uint256) = 1  # CCIP allows at most 1 distinct token per message
MAX_ADDRESS_BYTES: constant(uint256) = 32  # abi-encoded address (left-padded to 32 bytes)
MAX_EXTRA_ARGS_SIZE: constant(uint256) = 68  # 4-byte tag + abi(GenericExtraArgsV2) (= 4 + 64)

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


# https://docs.chain.link/ccip/api-reference/evm/v1.6.1/client#evmtokenamount
struct EVMTokenAmount:
    token: address
    amount: uint256

# https://docs.chain.link/ccip/api-reference/evm/v1.6.1/client#evm2anymessage
struct EVM2AnyMessage:
    receiver: Bytes[MAX_ADDRESS_BYTES]
    data: Bytes[MAX_DATA_SIZE]
    token_amounts: DynArray[EVMTokenAmount, MAX_TOKENS_PER_MESSAGE]
    fee_token: address
    extra_args: Bytes[MAX_EXTRA_ARGS_SIZE]

# https://docs.chain.link/ccip/api-reference/evm/v1.6.1/client#any2evmmessage
struct Any2EVMMessage:
    message_id: bytes32
    source_chain_selector: uint64
    sender: Bytes[MAX_ADDRESS_BYTES]
    data: Bytes[MAX_DATA_SIZE]
    dest_token_amounts: DynArray[EVMTokenAmount, MAX_TOKENS_PER_MESSAGE]

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
    # Zero router disables the CCIP path (mirrors a zero CRE forwarder)
    if _ccip_router == empty(address):
        log CCIPSecurityWarning(message="CCIP is disabled")
    self.router = _ccip_router
    log SetRouter(router=_ccip_router)


################################################################
#                      OWNER FUNCTIONS                         #
################################################################


@external
def set_router(_ccip_router: address):
    """
    @notice Set the CCIP router
    @dev Necessary for any potential upgrades to the router tech.
         Setting to empty(address) disables the CCIP path.
    """
    ownable._check_owner()

    if _ccip_router == empty(address):
        log CCIPSecurityWarning(message="CCIP is disabled")
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


@internal
def _transmit(
    _destination_chain_selector: uint64,
    _message: EVM2AnyMessage,
    _max_fee: uint256
    ) -> (bytes32, uint256):
    """
    @dev See https://docs.chain.link/ccip/supported-networks/mainnet for chain selectors
    """
    # Only transmit to a registered receiver, and only if the message targets it
    receiver: address = self._get_receiver_or_revert(_destination_chain_selector)
    assert abi_decode(_message.receiver, address) == receiver, "Receiver mismatch"

    fee: uint256 = self._quote(_destination_chain_selector, _message, False)  # allow_unsupported
    assert fee <= _max_fee, "Too high fees"
    message_id: bytes32 = extcall Router(self.router).ccipSend(_destination_chain_selector, _message, value=fee)
    return message_id, fee


@view
@internal
def _quote(_destination_chain_selector: uint64, message: EVM2AnyMessage, allow_unsupported: bool = False) -> uint256:
    if allow_unsupported and not staticcall Router(self.router).isChainSupported(_destination_chain_selector):
        return 0
    return staticcall Router(self.router).getFee(
        _destination_chain_selector,
        message
    )


@internal
@pure
def build_extra_args(gas_limit: uint256) -> Bytes[MAX_EXTRA_ARGS_SIZE]:
    # allow_out_of_order_execution is always True: in-order execution is being
    # deprecated by CCIP in early 2026.
    # https://docs.chain.link/ccip/concepts/best-practices/evm#setting-allowoutoforderexecution
    extra_args: Bytes[MAX_EXTRA_ARGS_SIZE] = abi_encode(
        GenericExtraArgsV2(gas_limit=gas_limit, allow_out_of_order_execution=True),
        method_id=GENERIC_EXTRA_ARGS_V2_TAG
    )
    return extra_args



@internal
@pure
def build_simple_message(receiver: address, data: Bytes[MAX_DATA_SIZE], extra_args: Bytes[MAX_EXTRA_ARGS_SIZE]) -> EVM2AnyMessage:
    message: EVM2AnyMessage = EVM2AnyMessage(
            receiver=abi_encode(receiver),
            data=data,
            token_amounts=empty(DynArray[EVMTokenAmount, MAX_TOKENS_PER_MESSAGE]),
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


@view
@internal
def _ccipReceive(_message: Any2EVMMessage):
    """
    @notice Authenticate an inbound CCIP message: router caller + registered sender.
    @dev A consuming ccipReceive() MUST call this first, before decoding or acting on data.
    """
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
