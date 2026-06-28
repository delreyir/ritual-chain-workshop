// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @title RitualBountyJudge - Advanced track: Ritual-native hidden submissions
/// @notice Instead of a two-step commit-reveal, answers are encrypted to a
///         Ritual TEE executor and stay ciphertext on-chain. They are only ever
///         decrypted INSIDE the enclave, at judging time, and all answers are
///         judged in a SINGLE batched LLM call. No reveal transaction is needed
///         and the plaintext is never published on-chain.
///
/// ## Where plaintext answers exist
///  - In the participant's browser/CLI at encryption time (before submission).
///  - Inside the TEE enclave during `judgeAll` (decrypted from `encryptedSecrets`).
///  Nowhere else. The chain, the mempool, logs and receipts only ever see
///  ciphertext + a keccak commitment.
///
/// ## On-chain vs off-chain
///  - ON-CHAIN: ECIES ciphertext of each answer, the submitter address, and an
///    integrity commitment keccak256(answer, salt, submitter, bountyId).
///  - OFF-CHAIN: the plaintext answers, the executor's public key (read from
///    TEEServiceRegistry), and the assembled LLM request (built by the owner).
///
/// ## How the LLM receives submissions for batch judging
///  The owner builds ONE LLM precompile request off-chain whose `encryptedSecrets`
///  array carries every submission's ciphertext, names them {{ANSWER_0}},
///  {{ANSWER_1}}, ... and references those templates from a single prompt that
///  also embeds the rubric. With `piiEnabled = true`, the TEE decrypts the
///  secrets and substitutes them inside the enclave, runs the model once over
///  the whole batch, and returns a ranking. One call, not one-per-answer.
contract RitualBountyJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 50;
    uint256 public constant MAX_CIPHERTEXT_BYTES = 8_000;

    uint256 public nextBountyId = 1;

    struct EncSubmission {
        address submitter;
        bytes encryptedAnswer; // ECIES ciphertext, decryptable only inside the TEE
        bytes32 commitment; // keccak256(answer, salt, submitter, bountyId)
        bool audited; // submitter later proved plaintext matches the commitment
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submitDeadline; // encrypted submissions accepted until here
        address executor; // TEE executor the answers were encrypted to
        bool judged;
        bool finalized;
        bytes aiReview; // raw LLM completion (ranking / winner decision)
        uint256 winnerIndex;
        // Final reveal: off-chain bundle of all revealed answers, committed to
        // on-chain by hash so large plaintext never hits storage.
        string revealedAnswersRef; // e.g. ipfs://... or storage-ref://...
        bytes32 revealedAnswersHash; // keccak256 of the published bundle
        EncSubmission[] submissions;
        mapping(address => bool) hasSubmitted;
    }

    mapping(uint256 => Bounty) internal bounties;

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    // Flat, returnable view of a Bounty (omits the nested mapping/array).
    struct BountyView {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submitDeadline;
        address executor;
        bool judged;
        bool finalized;
        uint256 submissionCount;
        uint256 winnerIndex;
        bytes aiReview;
        string revealedAnswersRef;
        bytes32 revealedAnswersHash;
    }

    uint256 private _locked = 1;

    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        address executor,
        uint256 reward,
        uint256 submitDeadline
    );
    event EncryptedSubmitted(
        uint256 indexed bountyId,
        uint256 indexed index,
        address indexed submitter,
        bytes32 commitment
    );
    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);
    event RevealedBundlePublished(
        uint256 indexed bountyId,
        string revealedAnswersRef,
        bytes32 revealedAnswersHash
    );
    event SubmissionAudited(
        uint256 indexed bountyId,
        uint256 indexed index,
        address indexed submitter
    );
    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    /// @param executor TEE executor (from TEEServiceRegistry) whose public key
    ///        participants encrypt their answers to.
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submitDuration,
        address executor
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submitDuration > 0, "submit duration zero");
        require(executor != address(0), "executor required");

        bountyId = nextBountyId++;

        Bounty storage b = bounties[bountyId];
        b.owner = msg.sender;
        b.title = title;
        b.rubric = rubric;
        b.reward = msg.value;
        b.submitDeadline = block.timestamp + submitDuration;
        b.executor = executor;
        b.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            executor,
            msg.value,
            b.submitDeadline
        );
    }

    /// @notice Submit an answer that is already ECIES-encrypted to the bounty's
    ///         TEE executor. Only ciphertext touches the chain.
    /// @param encryptedAnswer ECIES ciphertext of the plaintext answer.
    /// @param commitment keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)),
    ///        kept so the submitter can later prove authorship without trusting
    ///        the ciphertext alone.
    function submitEncrypted(
        uint256 bountyId,
        bytes calldata encryptedAnswer,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(block.timestamp < b.submitDeadline, "submissions closed");
        require(!b.judged && !b.finalized, "judging started");
        require(encryptedAnswer.length > 0, "empty ciphertext");
        require(
            encryptedAnswer.length <= MAX_CIPHERTEXT_BYTES,
            "ciphertext too long"
        );
        require(commitment != bytes32(0), "empty commitment");
        require(b.submissions.length < MAX_SUBMISSIONS, "too many submissions");
        require(!b.hasSubmitted[msg.sender], "already submitted");

        b.hasSubmitted[msg.sender] = true;
        b.submissions.push(
            EncSubmission({
                submitter: msg.sender,
                encryptedAnswer: encryptedAnswer,
                commitment: commitment,
                audited: false
            })
        );

        emit EncryptedSubmitted(
            bountyId,
            b.submissions.length - 1,
            msg.sender,
            commitment
        );
    }

    /// @notice Batch-judge all encrypted answers in a single LLM call. The
    ///         decryption happens inside the TEE (driven by `encryptedSecrets`
    ///         + `piiEnabled` packed into `llmInput`), never on-chain.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(block.timestamp >= b.submitDeadline, "submissions still open");
        require(!b.judged, "already judged");
        require(!b.finalized, "already finalized");
        require(b.submissions.length > 0, "no submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        b.judged = true;
        b.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /// @notice Optional public audit: after judging, a participant can reveal
    ///         their (answer, salt) so anyone can verify the stored ciphertext
    ///         really committed to that plaintext. Pure integrity check; the
    ///         answer is not stored, only flagged as audited.
    function auditSubmission(
        uint256 bountyId,
        uint256 index,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(index < b.submissions.length, "invalid index");

        EncSubmission storage s = b.submissions[index];
        require(s.submitter == msg.sender, "not your submission");
        require(!s.audited, "already audited");

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(expected == s.commitment, "commitment mismatch");

        s.audited = true;
        emit SubmissionAudited(bountyId, index, msg.sender);
    }

    /// @notice Final reveal (PDF "Suggested Reveal Pattern"): after judging, the
    ///         owner publishes an off-chain bundle of ALL revealed answers and
    ///         commits to it on-chain with only a reference + hash. Anyone can
    ///         fetch the bundle from `revealedAnswersRef` and verify
    ///         keccak256(bundle) == revealedAnswersHash. Large plaintext never
    ///         touches contract storage.
    function publishRevealedBundle(
        uint256 bountyId,
        string calldata revealedAnswersRef,
        bytes32 revealedAnswersHash
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(b.judged, "not judged yet");
        require(revealedAnswersHash != bytes32(0), "empty hash");
        require(bytes(revealedAnswersRef).length > 0, "empty ref");

        b.revealedAnswersRef = revealedAnswersRef;
        b.revealedAnswersHash = revealedAnswersHash;

        emit RevealedBundlePublished(
            bountyId,
            revealedAnswersRef,
            revealedAnswersHash
        );
    }

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) nonReentrant {
        Bounty storage b = bounties[bountyId];

        require(b.judged, "not judged yet");
        require(!b.finalized, "already finalized");
        require(winnerIndex < b.submissions.length, "invalid winner");

        b.finalized = true;
        b.winnerIndex = winnerIndex;

        address winner = b.submissions[winnerIndex].submitter;
        uint256 reward = b.reward;
        b.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // --- Views --------------------------------------------------------------

    function getBounty(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (BountyView memory) {
        Bounty storage b = bounties[bountyId];
        return
            BountyView({
                owner: b.owner,
                title: b.title,
                rubric: b.rubric,
                reward: b.reward,
                submitDeadline: b.submitDeadline,
                executor: b.executor,
                judged: b.judged,
                finalized: b.finalized,
                submissionCount: b.submissions.length,
                winnerIndex: b.winnerIndex,
                aiReview: b.aiReview,
                revealedAnswersRef: b.revealedAnswersRef,
                revealedAnswersHash: b.revealedAnswersHash
            });
    }

    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes memory encryptedAnswer,
            bytes32 commitment,
            bool audited
        )
    {
        Bounty storage b = bounties[bountyId];
        require(index < b.submissions.length, "invalid index");
        EncSubmission storage s = b.submissions[index];
        return (s.submitter, s.encryptedAnswer, s.commitment, s.audited);
    }

    function getSubmissionCount(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (uint256) {
        return bounties[bountyId].submissions.length;
    }
}
