// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BountyJudge} from "./BountyJudge.sol";

/// @notice Unit tests for the commit-reveal BountyJudge. Focuses on the reveal
///         cases the assignment asks for, plus the full lifecycle and payout.
///         The Ritual LLM precompile (0x0802) does not exist on the local EVM,
///         so `judgeAll` is exercised with `vm.mockCall`.
contract BountyJudgeTest is Test {
    BountyJudge internal judge;

    address internal alice;
    address internal bob;
    address internal carol;

    uint256 internal constant REWARD = 1 ether;
    uint256 internal constant COMMIT_DUR = 1 days;
    uint256 internal constant REVEAL_DUR = 1 days;

    address internal constant LLM_PRECOMPILE = address(0x0802);

    // Re-declared to use with vm.expectEmit.
    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        bytes32 commitment
    );
    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    function setUp() public {
        judge = new BountyJudge();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        // The test contract is the bounty owner; fund it to escrow rewards.
        vm.deal(address(this), 100 ether);
        // Start at a sane, non-zero timestamp.
        vm.warp(1_000);
    }

    // --- helpers ------------------------------------------------------------

    function _createBounty() internal returns (uint256 id) {
        id = judge.createBounty{value: REWARD}(
            "Best gas optimization",
            "Reward the clearest, most correct answer.",
            COMMIT_DUR,
            REVEAL_DUR
        );
    }

    function _deadlines(
        uint256 id
    ) internal view returns (uint256 commitDL, uint256 revealDL) {
        BountyJudge.BountyView memory v = judge.getBounty(id);
        return (v.commitDeadline, v.revealDeadline);
    }

    function _commit(
        uint256 id,
        address who,
        string memory answer,
        bytes32 salt
    ) internal {
        bytes32 c = judge.computeCommitment(answer, salt, who, id);
        vm.prank(who);
        judge.submitCommitment(id, c);
    }

    /// Mock the LLM precompile so judgeAll succeeds and stores `review`.
    function _mockLLM(bytes memory review) internal {
        BountyJudge.ConvoHistory memory convo = BountyJudge.ConvoHistory(
            "",
            "",
            ""
        );
        bytes memory actualOutput = abi.encode(
            false, // hasError
            review, // completionData
            bytes(""), // modelMetadata
            string(""), // errorMessage
            convo // updatedConvoHistory
        );
        // Short-running async precompile envelope: (simmedInput, actualOutput).
        bytes memory envelope = abi.encode(bytes(""), actualOutput);
        vm.mockCall(LLM_PRECOMPILE, bytes(""), envelope);
    }

    // --- createBounty -------------------------------------------------------

    function test_createBounty_storesFields() public {
        uint256 id = _createBounty();
        BountyJudge.BountyView memory v = judge.getBounty(id);

        assertEq(v.owner, address(this));
        assertEq(v.title, "Best gas optimization");
        assertEq(v.reward, REWARD);
        assertEq(v.commitDeadline, 1_000 + COMMIT_DUR);
        assertEq(v.revealDeadline, 1_000 + COMMIT_DUR + REVEAL_DUR);
        assertFalse(v.judged);
        assertFalse(v.finalized);
        assertEq(v.commitmentCount, 0);
        assertEq(v.revealedCount, 0);
        assertEq(v.winnerIndex, type(uint256).max);
    }

    function test_createBounty_revertsWithoutReward() public {
        vm.expectRevert(bytes("reward required"));
        judge.createBounty("t", "r", COMMIT_DUR, REVEAL_DUR);
    }

    function test_currentPhase_progression() public {
        uint256 id = _createBounty();
        (uint256 commitDL, uint256 revealDL) = _deadlines(id);

        assertEq(uint256(judge.currentPhase(id)), uint256(BountyJudge.Phase.Commit));
        vm.warp(commitDL);
        assertEq(uint256(judge.currentPhase(id)), uint256(BountyJudge.Phase.Reveal));
        vm.warp(revealDL);
        assertEq(uint256(judge.currentPhase(id)), uint256(BountyJudge.Phase.Judging));
    }

    // --- submitCommitment ---------------------------------------------------

    function test_submitCommitment_works() public {
        uint256 id = _createBounty();
        bytes32 c = judge.computeCommitment("answer", bytes32(uint256(1)), alice, id);

        vm.expectEmit(true, true, false, true);
        emit CommitmentSubmitted(id, alice, c);

        vm.prank(alice);
        judge.submitCommitment(id, c);

        (bytes32 hash, bool exists, bool revealed) = judge.getCommitment(id, alice);
        assertEq(hash, c);
        assertTrue(exists);
        assertFalse(revealed);
    }

    function test_submitCommitment_revertsAfterDeadline() public {
        uint256 id = _createBounty();
        (uint256 commitDL, ) = _deadlines(id);
        vm.warp(commitDL); // exactly at deadline -> closed (strict <)

        bytes32 c = judge.computeCommitment("a", bytes32(0), alice, id);
        vm.prank(alice);
        vm.expectRevert(bytes("commit phase closed"));
        judge.submitCommitment(id, c);
    }

    function test_submitCommitment_revertsOnDoubleCommit() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", bytes32(uint256(7)));

        bytes32 c2 = judge.computeCommitment("b", bytes32(uint256(8)), alice, id);
        vm.prank(alice);
        vm.expectRevert(bytes("already committed"));
        judge.submitCommitment(id, c2);
    }

    function test_submitCommitment_revertsOnEmptyCommitment() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        vm.expectRevert(bytes("empty commitment"));
        judge.submitCommitment(id, bytes32(0));
    }

    function test_submitCommitment_revertsOnUnknownBounty() public {
        vm.prank(alice);
        vm.expectRevert(bytes("bounty not found"));
        judge.submitCommitment(999, bytes32(uint256(1)));
    }

    // --- revealAnswer: the core cases --------------------------------------

    function test_reveal_validRevealSucceeds() public {
        uint256 id = _createBounty();
        string memory answer = "use unchecked blocks in the loop";
        bytes32 salt = keccak256("alice-salt");
        _commit(id, alice, answer, salt);

        (uint256 commitDL, ) = _deadlines(id);
        vm.warp(commitDL); // reveal phase open

        vm.prank(alice);
        judge.revealAnswer(id, answer, salt);

        (, bool exists, bool revealed) = judge.getCommitment(id, alice);
        assertTrue(exists);
        assertTrue(revealed);
        assertEq(judge.getRevealedCount(id), 1);

        (address submitter, string memory storedAnswer) = judge
            .getRevealedSubmission(id, 0);
        assertEq(submitter, alice);
        assertEq(storedAnswer, answer);
    }

    function test_reveal_wrongSaltReverts() public {
        uint256 id = _createBounty();
        string memory answer = "answer";
        bytes32 salt = keccak256("right-salt");
        _commit(id, alice, answer, salt);

        (uint256 commitDL, ) = _deadlines(id);
        vm.warp(commitDL);

        vm.prank(alice);
        vm.expectRevert(bytes("reveal mismatch"));
        judge.revealAnswer(id, answer, keccak256("wrong-salt"));
    }

    function test_reveal_wrongAnswerReverts() public {
        uint256 id = _createBounty();
        bytes32 salt = keccak256("salt");
        _commit(id, alice, "correct answer", salt);

        (uint256 commitDL, ) = _deadlines(id);
        vm.warp(commitDL);

        vm.prank(alice);
        vm.expectRevert(bytes("reveal mismatch"));
        judge.revealAnswer(id, "tampered answer", salt);
    }

    function test_reveal_wrongSenderCannotStealCommitment() public {
        // alice commits; bob (also committed) tries to reveal alice's pair.
        uint256 id = _createBounty();
        string memory answer = "alice's answer";
        bytes32 salt = keccak256("alice-salt");
        _commit(id, alice, answer, salt);
        _commit(id, bob, "bob's own", keccak256("bob-salt"));

        (uint256 commitDL, ) = _deadlines(id);
        vm.warp(commitDL);

        // bob's stored hash is bound to bob, so alice's (answer,salt) mismatches.
        vm.prank(bob);
        vm.expectRevert(bytes("reveal mismatch"));
        judge.revealAnswer(id, answer, salt);
    }

    function test_reveal_revertsWithoutCommitment() public {
        uint256 id = _createBounty();
        (uint256 commitDL, ) = _deadlines(id);
        vm.warp(commitDL);

        vm.prank(carol); // never committed
        vm.expectRevert(bytes("no commitment"));
        judge.revealAnswer(id, "x", bytes32(0));
    }

    function test_reveal_revertsBeforeRevealPhase() public {
        uint256 id = _createBounty();
        string memory answer = "early";
        bytes32 salt = keccak256("s");
        _commit(id, alice, answer, salt);

        // still in commit phase
        vm.prank(alice);
        vm.expectRevert(bytes("reveal not started"));
        judge.revealAnswer(id, answer, salt);
    }

    function test_reveal_revertsAfterRevealDeadline() public {
        uint256 id = _createBounty();
        string memory answer = "late";
        bytes32 salt = keccak256("s");
        _commit(id, alice, answer, salt);

        (, uint256 revealDL) = _deadlines(id);
        vm.warp(revealDL); // exactly at reveal deadline -> closed

        vm.prank(alice);
        vm.expectRevert(bytes("reveal phase closed"));
        judge.revealAnswer(id, answer, salt);
    }

    function test_reveal_revertsOnDoubleReveal() public {
        uint256 id = _createBounty();
        string memory answer = "a";
        bytes32 salt = keccak256("s");
        _commit(id, alice, answer, salt);

        (uint256 commitDL, ) = _deadlines(id);
        vm.warp(commitDL);

        vm.prank(alice);
        judge.revealAnswer(id, answer, salt);

        vm.prank(alice);
        vm.expectRevert(bytes("already revealed"));
        judge.revealAnswer(id, answer, salt);
    }

    function test_reveal_answerTooLongReverts() public {
        uint256 id = _createBounty();
        bytes memory big = new bytes(2_001);
        string memory answer = string(big);
        bytes32 salt = keccak256("s");
        _commit(id, alice, answer, salt);

        (uint256 commitDL, ) = _deadlines(id);
        vm.warp(commitDL);

        vm.prank(alice);
        vm.expectRevert(bytes("answer too long"));
        judge.revealAnswer(id, answer, salt);
    }

    // --- judgeAll -----------------------------------------------------------

    function test_judgeAll_happyPath() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer A", keccak256("sa"));
        _commit(id, bob, "answer B", keccak256("sb"));

        (uint256 commitDL, uint256 revealDL) = _deadlines(id);
        vm.warp(commitDL);
        vm.prank(alice);
        judge.revealAnswer(id, "answer A", keccak256("sa"));
        vm.prank(bob);
        judge.revealAnswer(id, "answer B", keccak256("sb"));

        vm.warp(revealDL);
        _mockLLM(bytes("winner: index 0"));
        judge.judgeAll(id, bytes("ignored-because-mocked"));

        BountyJudge.BountyView memory v = judge.getBounty(id);
        assertTrue(v.judged);
        assertEq(string(v.aiReview), "winner: index 0");
    }

    function test_judgeAll_revertsBeforeRevealClosed() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa"));
        (uint256 commitDL, ) = _deadlines(id);
        vm.warp(commitDL);
        vm.prank(alice);
        judge.revealAnswer(id, "a", keccak256("sa"));

        // reveal window still open
        _mockLLM(bytes("x"));
        vm.expectRevert(bytes("reveal not finished"));
        judge.judgeAll(id, bytes(""));
    }

    function test_judgeAll_revertsForNonOwner() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa"));
        (uint256 commitDL, uint256 revealDL) = _deadlines(id);
        vm.warp(commitDL);
        vm.prank(alice);
        judge.revealAnswer(id, "a", keccak256("sa"));
        vm.warp(revealDL);

        vm.prank(bob);
        vm.expectRevert(bytes("not bounty owner"));
        judge.judgeAll(id, bytes(""));
    }

    function test_judgeAll_revertsWithNoReveals() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa")); // committed but never revealed
        (, uint256 revealDL) = _deadlines(id);
        vm.warp(revealDL);

        _mockLLM(bytes("x"));
        vm.expectRevert(bytes("no revealed answers"));
        judge.judgeAll(id, bytes(""));
    }

    function test_judgeAll_revertsOnDoubleJudge() public {
        uint256 id = _fullyRevealedBounty();
        (, uint256 revealDL) = _deadlines(id);
        vm.warp(revealDL);

        _mockLLM(bytes("review"));
        judge.judgeAll(id, bytes(""));

        vm.expectRevert(bytes("already judged"));
        judge.judgeAll(id, bytes(""));
    }

    // --- finalizeWinner -----------------------------------------------------

    function test_finalizeWinner_paysWinner() public {
        uint256 id = _fullyRevealedBounty(); // alice index 0, bob index 1
        (, uint256 revealDL) = _deadlines(id);
        vm.warp(revealDL);
        _mockLLM(bytes("winner 1"));
        judge.judgeAll(id, bytes(""));

        uint256 bobBefore = bob.balance;

        vm.expectEmit(true, true, true, true);
        emit WinnerFinalized(id, 1, bob, REWARD);
        judge.finalizeWinner(id, 1);

        assertEq(bob.balance, bobBefore + REWARD);

        BountyJudge.BountyView memory v = judge.getBounty(id);
        assertTrue(v.finalized);
        assertEq(v.winnerIndex, 1);
        assertEq(v.reward, 0);
    }

    function test_finalizeWinner_revertsBeforeJudged() public {
        uint256 id = _fullyRevealedBounty();
        (, uint256 revealDL) = _deadlines(id);
        vm.warp(revealDL);

        vm.expectRevert(bytes("not judged yet"));
        judge.finalizeWinner(id, 0);
    }

    function test_finalizeWinner_revertsForNonOwner() public {
        uint256 id = _fullyRevealedBounty();
        (, uint256 revealDL) = _deadlines(id);
        vm.warp(revealDL);
        _mockLLM(bytes("r"));
        judge.judgeAll(id, bytes(""));

        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        judge.finalizeWinner(id, 0);
    }

    function test_finalizeWinner_revertsOnInvalidIndex() public {
        uint256 id = _fullyRevealedBounty();
        (, uint256 revealDL) = _deadlines(id);
        vm.warp(revealDL);
        _mockLLM(bytes("r"));
        judge.judgeAll(id, bytes(""));

        vm.expectRevert(bytes("invalid winner"));
        judge.finalizeWinner(id, 99);
    }

    function test_finalizeWinner_revertsOnDoubleFinalize() public {
        uint256 id = _fullyRevealedBounty();
        (, uint256 revealDL) = _deadlines(id);
        vm.warp(revealDL);
        _mockLLM(bytes("r"));
        judge.judgeAll(id, bytes(""));
        judge.finalizeWinner(id, 0);

        vm.expectRevert(bytes("already finalized"));
        judge.finalizeWinner(id, 0);
    }

    // --- commitment helper --------------------------------------------------

    function testFuzz_computeCommitment_deterministic(
        string memory answer,
        bytes32 salt,
        address who,
        uint256 id
    ) public view {
        bytes32 a = judge.computeCommitment(answer, salt, who, id);
        bytes32 b = judge.computeCommitment(answer, salt, who, id);
        assertEq(a, b);
    }

    function test_computeCommitment_matchesManualEncoding() public view {
        string memory answer = "manual";
        bytes32 salt = bytes32(uint256(42));
        uint256 id = 1;
        bytes32 expected = keccak256(abi.encode(answer, salt, alice, id));
        assertEq(judge.computeCommitment(answer, salt, alice, id), expected);
    }

    // --- shared fixture -----------------------------------------------------

    /// Bounty with alice (index 0) and bob (index 1) both revealed.
    function _fullyRevealedBounty() internal returns (uint256 id) {
        id = _createBounty();
        _commit(id, alice, "answer A", keccak256("sa"));
        _commit(id, bob, "answer B", keccak256("sb"));
        (uint256 commitDL, ) = _deadlines(id);
        vm.warp(commitDL);
        vm.prank(alice);
        judge.revealAnswer(id, "answer A", keccak256("sa"));
        vm.prank(bob);
        judge.revealAnswer(id, "answer B", keccak256("sb"));
    }

    // allow this test contract to receive ETH if ever needed
    receive() external payable {}
}
