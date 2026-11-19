# Stake DAO Votemarket — `totalVotes = 1` PoC

Bug-bounty proof of concept for the Stake DAO Votemarket finding reported on
Mantis (Medium): `Verifier.setPointData()` registers `totalVotes = 1` for an
epoch whose Curve GaugeController weight was never recorded, overpaying the
first claimants at `maxRewardPerVote` and bricking later voters.

## What it proves

- `test/BiasOneFork.t.sol` — on a live mainnet fork, a real Merkle-Patricia
  exclusion proof (generated live via `eth_getProof` on the free public RPC,
  `script/gen_proof.py` — no hardcoded proof bytes) for a Curve
  GaugeController `points_weight[gauge][epoch].bias` slot recorded as `0` on
  mainnet is accepted by `Verifier.setPointData()`, which then records
  `totalVotes = 1`.
- `test/BiasOneLocal.t.sol` — local Votemarket + Oracle + OracleLens with a
  $100,000 USDC campaign scenario: voter A is paid $24,000 vs $2,500 fair
  (10x overpay); voter B's $12,500 claim reverts with
  `CLAIM_AMOUNT_EXCEEDS_REWARD_AMOUNT` and loses everything.

## Run it

```bash
forge test
```

Expected: **3 passed, 0 failed.** Free public RPC only
(`https://rpc.stakedao.org/main/evm/1`, see `foundry.toml`); no mainnet
transactions, no spend. Foundry with solc 0.8.28; `ffi = true` is required
(the fork test generates its proof live via `script/gen_proof.py`).

Submodules (`lib/forge-std`, `lib/solady`) are declared in `.gitmodules` —
run `git submodule update --init` after cloning if they are not present.

## Contracts under test

`src/verifiers/Verifier.sol` / `VerifierV2.sol` `setPointData()` (line ~104):
`if (weight.bias == 0) { weight.bias = 1; }`. The same pattern is present in
`VerifierPendle.sol` and `VerifierYB.sol`; this PoC covers the
Verifier/VerifierV2 path.
