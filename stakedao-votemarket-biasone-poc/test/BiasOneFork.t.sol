// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@forge-std/src/Test.sol";
import "src/interfaces/IGaugeController.sol";
import "src/oracle/Oracle.sol";
import "src/utils/StateProofVerifier.sol";
import "src/verifiers/Verifier.sol";

/// @notice PoC A — on a live mainnet fork, a REAL Merkle-Patricia exclusion proof
/// for the Curve GaugeController slot points_weight[gauge][epoch].bias (a slot
/// that was never written, because no vote touched this gauge in the prior
/// week) is accepted by Verifier.setPointData(), which then records
/// totalVotes = 1 ("We add manually 1 wei, to prevent the rollover").
///
/// Gauge used: 0xAEA6c312f4b3E04D752946d329693F7293bC2e6D, whose recorded bias
/// for the current epoch is 0 on mainnet (verified via eth_call before the
/// test). The exclusion proof is generated live from the free public RPC
/// via ffi (script/gen_proof.py) — no hardcoded proof bytes.
contract BiasOneForkTest is Test {
    Oracle public oracle;
    Verifier public verifier;

    address public constant GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;
    address public constant GAUGE = 0xAEA6c312f4b3E04D752946d329693F7293bC2e6D;

    uint256 public constant WEIGHT_SLOT = 12;
    uint256 public constant LAST_VOTE_SLOT = 11;
    uint256 public constant USER_SLOPE_SLOT = 9;

    function setUp() public {
        vm.createSelectFork("mainnet");
        oracle = new Oracle(address(this));
        verifier = new Verifier(address(oracle), GAUGE_CONTROLLER, LAST_VOTE_SLOT, USER_SLOPE_SLOT, WEIGHT_SLOT);
        oracle.setAuthorizedDataProvider(address(verifier));
        oracle.setAuthorizedBlockNumberProvider(address(this));
        oracle.setAuthorizedBlockNumberProvider(address(verifier));
    }

    function testExclusionProofRegistersBiasOne() public {
        uint256 epoch = block.timestamp / 1 weeks * 1 weeks;

        (uint256 realBias,) = IGaugeController(GAUGE_CONTROLLER).points_weight(GAUGE, epoch);
        emit log_named_uint("real GaugeController bias for epoch", realBias);
        assertEq(realBias, 0, "precondition: gauge bias unrecorded (0) for this epoch");

        (bytes32 blockHash, bytes memory blockHeaderRlp, bytes memory controllerProof, bytes memory storageProofRlp)
        = getProofs(GAUGE, epoch);

        oracle.insertBlockNumber(
            epoch,
            StateProofVerifier.BlockHeader({
                hash: blockHash,
                stateRootHash: bytes32(0),
                number: block.number,
                timestamp: block.timestamp
            })
        );

        verifier.setBlockData(blockHeaderRlp, controllerProof);

        IOracle.Point memory weight = verifier.setPointData(GAUGE, epoch, storageProofRlp);
        emit log_named_uint("registered totalVotes (bias)", weight.bias);
        assertEq(weight.bias, 1, "exclusion proof registered as totalVotes = 1");
        (uint256 storedBias,) = oracle.pointByEpoch(GAUGE, epoch);
        assertEq(storedBias, 1);
    }

    /// @notice Storage position of points_weight[gauge][epoch].bias under the
    /// V1 verifier slot scheme (same formula as votemarket-v2's Proof.t.sol).
    function gaugePointPosition(address gauge, uint256 epoch) internal pure returns (uint256) {
        return uint256(
            keccak256(abi.encode(keccak256(abi.encode(keccak256(abi.encode(WEIGHT_SLOT, gauge)), epoch))))
        );
    }

    function getProofs(address gauge, uint256 epoch)
        internal
        returns (bytes32 blockHash, bytes memory blockHeaderRlp, bytes memory controllerProof, bytes memory storageProofRlp)
    {
        uint256 position = gaugePointPosition(gauge, epoch);
        string[] memory inputs = new string[](5);
        inputs[0] = "proof-venv/bin/python";
        inputs[1] = "script/gen_proof.py";
        inputs[2] = vm.toString(GAUGE_CONTROLLER);
        inputs[3] = vm.toString(block.number);
        inputs[4] = vm.toString(position);
        return abi.decode(vm.ffi(inputs), (bytes32, bytes, bytes, bytes));
    }
}
