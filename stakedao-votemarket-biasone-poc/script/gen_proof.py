"""Generate RLP-encoded state proofs for the Votemarket BiasOne fork PoC.

Adapted from votemarket-v2's test/python/generate_proof.py, but uses the free
public StakeDAO RPC (no API key) instead of Alchemy.

Usage:
    python script/gen_proof.py <account> <block_number> <slot0> [<slot1> ...]

Prints 0x-prefixed abi.encode(bytes32 blockHash, bytes blockHeaderRlp,
bytes accountProof, bytes storageProofRlp) to stdout.
"""
import sys, rlp, os

from web3 import Web3
from eth_abi import encode
from hexbytes import HexBytes

RPC_URL = "https://rpc.stakedao.org/main/evm/1"

web3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"headers": {"User-Agent": "Mozilla/5.0"}}))

BLOCK_HEADER = (
    "parentHash",
    "sha3Uncles",
    "miner",
    "stateRoot",
    "transactionsRoot",
    "receiptsRoot",
    "logsBloom",
    "difficulty",
    "number",
    "gasLimit",
    "gasUsed",
    "timestamp",
    "extraData",
    "mixHash",
    "nonce",
    "baseFeePerGas",
    "withdrawalsRoot",
    "blobGasUsed",
    "excessBlobGas",
    "parentBeaconBlockRoot",
    "requestsHash",
)


INT_FIELDS = {
    "difficulty",
    "number",
    "gasLimit",
    "gasUsed",
    "timestamp",
    "baseFeePerGas",
    "blobGasUsed",
    "excessBlobGas",
}


def _field_bytes(key, value):
    if key in INT_FIELDS:
        n = value if isinstance(value, int) else int(value, 16)
        return b"" if n == 0 else n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes(HexBytes(value))


def encode_rlp_block(block):
    block_header = [
        _field_bytes(k, block[k]) for k in BLOCK_HEADER if k in block
    ]
    return rlp.encode(block_header)


def encode_rlp_proofs(proofs):
    account_proof = list(map(rlp.decode, map(HexBytes, proofs["accountProof"])))
    storage_proofs = [
        list(map(rlp.decode, map(HexBytes, proof["proof"])))
        for proof in proofs["storageProof"]
    ]
    return rlp.encode(account_proof), rlp.encode(storage_proofs)


def generate_proofs(account, proof, block_number):
    block = web3.eth.get_block(int(block_number))
    rlp_block = encode_rlp_block(block)
    account_proof, rlp_proof = encode_rlp_proofs(
        web3.eth.get_proof(account, proof, block_identifier=int(block_number))
    )
    data = encode(
        ["bytes32", "bytes", "bytes", "bytes"],
        [block["hash"], rlp_block, account_proof, rlp_proof],
    ).hex()
    print("0x" + data)


def main():
    args = sys.argv[1:]
    account = args[0]
    block_number = args[1]
    keys = [int(x) for x in args[2:]]
    return generate_proofs(account, keys, block_number)


if __name__ == "__main__":
    main()
