// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RitualBountyJudge} from "./RitualBountyJudge.sol";

/// @notice Tests for the advanced, Ritual-native hidden-submission flow.
///         Only ciphertext is stored on-chain; judging is a single mocked LLM
///         call (the real call decrypts inside the TEE).
contract RitualBountyJudgeTest is Test {
    RitualBountyJudge internal judge;

    address internal alice;
    address internal bob;
    address internal executor;

    uint256 internal constant REWARD = 1 ether;
    uint256 internal constant SUBMIT_DUR = 1 days;
    address internal constant LLM_PRECOMPILE = address(0x0802);

    function setUp() public {
        judge = new RitualBountyJudge();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        executor = makeAddr("executor");
        vm.deal(address(this), 100 ether);
        vm.warp(1_000);
    }

    function _createBounty() internal returns (uint256 id) {
        id = judge.createBounty{value: REWARD}(
            "Private bounty",
            "Pick the best answer.",
            SUBMIT_DUR,
            executor
        );
    }

    function _mockLLM(bytes memory review) internal {
        RitualBountyJudge.ConvoHistory memory convo = RitualBountyJudge
            .ConvoHistory("", "", "");
        bytes memory actualOutput = abi.encode(
            false,
            review,
            bytes(""),
            string(""),
            convo
        );
        bytes memory envelope = abi.encode(bytes(""), actualOutput);
        vm.mockCall(LLM_PRECOMPILE, bytes(""), envelope);
    }

    function _submitDeadline(uint256 id) internal view returns (uint256) {
        return judge.getBounty(id).submitDeadline;
    }

    function test_submitEncrypted_storesCiphertextOnly() public {
        uint256 id = _createBounty();
        bytes memory ct = hex"deadbeefcafe";
        bytes32 commitment = keccak256(
            abi.encode("plain answer", bytes32(uint256(1)), alice, id)
        );

        vm.prank(alice);
        judge.submitEncrypted(id, ct, commitment);

        (
            address submitter,
            bytes memory storedCt,
            bytes32 storedCommit,
            bool audited
        ) = judge.getSubmission(id, 0);
        assertEq(submitter, alice);
        assertEq(storedCt, ct);
        assertEq(storedCommit, commitment);
        assertFalse(audited);
        assertEq(judge.getSubmissionCount(id), 1);
    }

    function test_submitEncrypted_revertsAfterDeadline() public {
        uint256 id = _createBounty();
        vm.warp(_submitDeadline(id));
        vm.prank(alice);
        vm.expectRevert(bytes("submissions closed"));
        judge.submitEncrypted(id, hex"01", keccak256("x"));
    }

    function test_submitEncrypted_revertsOnDoubleSubmit() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitEncrypted(id, hex"01", keccak256("a"));
        vm.prank(alice);
        vm.expectRevert(bytes("already submitted"));
        judge.submitEncrypted(id, hex"02", keccak256("b"));
    }

    function test_judgeAll_batchHappyPath() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitEncrypted(id, hex"aa", keccak256("a"));
        vm.prank(bob);
        judge.submitEncrypted(id, hex"bb", keccak256("b"));

        vm.warp(_submitDeadline(id));
        _mockLLM(bytes("ranking: [1,0]"));
        judge.judgeAll(id, bytes("batched-llm-request"));

        RitualBountyJudge.BountyView memory v = judge.getBounty(id);
        assertTrue(v.judged);
        assertEq(string(v.aiReview), "ranking: [1,0]");
        assertEq(v.submissionCount, 2);
    }

    function test_judgeAll_revertsWhileOpen() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitEncrypted(id, hex"aa", keccak256("a"));
        _mockLLM(bytes("x"));
        vm.expectRevert(bytes("submissions still open"));
        judge.judgeAll(id, bytes(""));
    }

    function test_auditSubmission_verifiesCommitment() public {
        uint256 id = _createBounty();
        string memory answer = "the real answer";
        bytes32 salt = keccak256("salt");
        bytes32 commitment = keccak256(abi.encodePacked(answer, salt, alice, id));

        vm.prank(alice);
        judge.submitEncrypted(id, hex"aa", commitment);

        // wrong (answer, salt) fails
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.auditSubmission(id, 0, "wrong", salt);

        // correct pair passes
        vm.prank(alice);
        judge.auditSubmission(id, 0, answer, salt);

        (, , , bool audited) = judge.getSubmission(id, 0);
        assertTrue(audited);
    }

    function test_finalizeWinner_paysWinner() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitEncrypted(id, hex"aa", keccak256("a"));
        vm.prank(bob);
        judge.submitEncrypted(id, hex"bb", keccak256("b"));
        vm.warp(_submitDeadline(id));
        _mockLLM(bytes("winner 0"));
        judge.judgeAll(id, bytes(""));

        uint256 aliceBefore = alice.balance;
        judge.finalizeWinner(id, 0);
        assertEq(alice.balance, aliceBefore + REWARD);

        RitualBountyJudge.BountyView memory v = judge.getBounty(id);
        assertTrue(v.finalized);
        assertEq(v.winnerIndex, 0);
    }

    function test_publishRevealedBundle_storesRefAndHash() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitEncrypted(id, hex"aa", keccak256("a"));
        vm.warp(_submitDeadline(id));
        _mockLLM(bytes("winner 0"));
        judge.judgeAll(id, bytes(""));

        string memory ref = "ipfs://bafy.../bundle.json";
        bytes32 h = keccak256(bytes("the full revealed answers bundle"));
        judge.publishRevealedBundle(id, ref, h);

        RitualBountyJudge.BountyView memory v = judge.getBounty(id);
        assertEq(v.revealedAnswersRef, ref);
        assertEq(v.revealedAnswersHash, h);
    }

    function test_publishRevealedBundle_revertsBeforeJudged() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitEncrypted(id, hex"aa", keccak256("a"));
        vm.expectRevert(bytes("not judged yet"));
        judge.publishRevealedBundle(id, "ipfs://x", keccak256("x"));
    }

    function test_publishRevealedBundle_revertsForNonOwner() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitEncrypted(id, hex"aa", keccak256("a"));
        vm.warp(_submitDeadline(id));
        _mockLLM(bytes("r"));
        judge.judgeAll(id, bytes(""));
        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        judge.publishRevealedBundle(id, "ipfs://x", keccak256("x"));
    }

    receive() external payable {}
}
