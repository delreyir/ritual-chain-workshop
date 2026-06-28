// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;

    function depositFor(address user, uint256 lockDuration) external payable;

    function withdraw(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    function lockUntil(address) external view returns (uint256);
}

/// @title BountyJudge - Privacy-preserving AI bounty judge (commit-reveal)
/// @notice Refines the original `AIJudge` where submissions were public. Here
///         participants first publish ONLY a commitment hash. After the
///         submission deadline they reveal the plaintext answer + salt, and the
///         contract verifies the commitment before the answer becomes eligible
///         for AI judging. This stops participants from copying and improving
///         on each other's answers during the submission window.
///
/// @dev Commitment scheme (must be reproduced off-chain / in the frontend):
///         commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
///      Binding the hash to `msg.sender` and `bountyId` means a leaked
///      (answer, salt) pair cannot be replayed by another address or reused on
///      another bounty. (encodePacked is unambiguous here: only one dynamic
///      field `answer`, and it is first.)
contract BountyJudge is PrecompileConsumer {
    // --- Limits -------------------------------------------------------------

    uint256 public constant MAX_SUBMISSIONS = 50;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    // --- Storage ------------------------------------------------------------

    uint256 public nextBountyId = 1;

    /// @notice Ritual fee-escrow used to pay for precompile (LLM) calls on
    ///         Ritual Chain. Unused on plain EVM chains, kept for parity with
    ///         the workshop scaffold.
    IRitualWallet public wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    enum Phase {
        Commit, // accepting commitment hashes
        Reveal, // accepting reveals, submissions are closed
        Judging, // reveal window over, awaiting AI judging
        Finalized // winner paid
    }

    struct Commitment {
        bytes32 hash; // keccak256(answer, salt, submitter, bountyId)
        bool exists; // a commitment was submitted by this address
        bool revealed; // the answer has been revealed and verified
    }

    struct Revealed {
        address submitter;
        string answer;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 commitDeadline; // commitments accepted while block.timestamp < commitDeadline
        uint256 revealDeadline; // reveals accepted while commitDeadline <= ts < revealDeadline
        bool judged;
        bool finalized;
        bytes aiReview; // raw LLM completion bytes (the AI's review/ranking)
        uint256 winnerIndex; // index into revealedList, type(uint256).max until set
        uint256 commitmentCount;
        Revealed[] revealedList;
        mapping(address => Commitment) commitments;
    }

    // Bounty holds a nested mapping, so it cannot be returned wholesale; keep it
    // internal and expose explicit getters below.
    mapping(uint256 => Bounty) internal bounties;

    // ConvoHistory mirrors the trailing tuple of the LLM precompile response so
    // the completion can be abi.decoded. Unused fields are ignored.
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
        uint256 commitDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        uint256 commitmentCount;
        uint256 revealedCount;
        uint256 winnerIndex;
        bytes aiReview;
    }

    // --- Reentrancy guard ---------------------------------------------------

    uint256 private _locked = 1;

    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    // --- Events -------------------------------------------------------------

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 commitDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed revealIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // --- Modifiers ----------------------------------------------------------

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    // --- Bounty lifecycle ---------------------------------------------------

    /// @notice Create a bounty and escrow the reward.
    /// @param title Human-readable title.
    /// @param rubric Judging rubric handed to the AI judge.
    /// @param commitDuration Length of the commit (submission) phase, expressed
    ///        in `block.timestamp` units: seconds on most EVM chains, but
    ///        MILLISECONDS on Ritual Chain (sub-second blocks).
    /// @param revealDuration Length of the reveal phase, same units as above.
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 commitDuration,
        uint256 revealDuration
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(commitDuration > 0, "commit duration zero");
        require(revealDuration > 0, "reveal duration zero");

        bountyId = nextBountyId++;

        Bounty storage b = bounties[bountyId];
        b.owner = msg.sender;
        b.title = title;
        b.rubric = rubric;
        b.reward = msg.value;
        b.commitDeadline = block.timestamp + commitDuration;
        b.revealDeadline = b.commitDeadline + revealDuration;
        b.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            b.commitDeadline,
            b.revealDeadline
        );
    }

    /// @notice Phase 1 - submit only the commitment hash. The plaintext answer
    ///         stays off-chain (and secret) until the reveal phase.
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(block.timestamp < b.commitDeadline, "commit phase closed");
        require(commitment != bytes32(0), "empty commitment");
        require(b.commitmentCount < MAX_SUBMISSIONS, "too many submissions");

        Commitment storage c = b.commitments[msg.sender];
        require(!c.exists, "already committed");

        c.hash = commitment;
        c.exists = true;
        b.commitmentCount++;

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    /// @notice Phase 2 - reveal the plaintext answer and salt. The contract
    ///         recomputes the commitment and only accepts the answer if it
    ///         matches the hash submitted earlier by the SAME address.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(block.timestamp >= b.commitDeadline, "reveal not started");
        require(block.timestamp < b.revealDeadline, "reveal phase closed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        Commitment storage c = b.commitments[msg.sender];
        require(c.exists, "no commitment");
        require(!c.revealed, "already revealed");

        bytes32 expected = computeCommitment(
            answer,
            salt,
            msg.sender,
            bountyId
        );
        require(expected == c.hash, "reveal mismatch");

        c.revealed = true;
        b.revealedList.push(Revealed({submitter: msg.sender, answer: answer}));

        emit AnswerRevealed(bountyId, b.revealedList.length - 1, msg.sender);
    }

    /// @notice Phase 3 - batch-judge every revealed answer with one LLM call.
    /// @dev `llmInput` is the ABI-encoded Ritual LLM precompile request built
    ///      off-chain. It should embed the rubric and all revealed answers in a
    ///      single prompt so the model judges the whole batch at once (not one
    ///      call per answer). Can only run after the reveal window closes.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(block.timestamp >= b.revealDeadline, "reveal not finished");
        require(!b.judged, "already judged");
        require(!b.finalized, "already finalized");
        require(b.revealedList.length > 0, "no revealed answers");

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

    /// @notice Phase 4 - the bounty owner finalizes the AI-recommended winner
    ///         and the escrowed reward is paid out.
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) nonReentrant {
        Bounty storage b = bounties[bountyId];

        require(b.judged, "not judged yet");
        require(!b.finalized, "already finalized");
        require(winnerIndex < b.revealedList.length, "invalid winner");

        // checks-effects-interactions: flip state before sending ETH.
        b.finalized = true;
        b.winnerIndex = winnerIndex;

        address winner = b.revealedList[winnerIndex].submitter;
        uint256 reward = b.reward;
        b.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // --- Views / helpers ----------------------------------------------------

    /// @notice Canonical commitment hash. Use the exact same encoding off-chain.
    /// @dev Matches the homework's suggested formula:
    ///      keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)).
    function computeCommitment(
        string memory answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }

    /// @notice Current lifecycle phase, derived from time + flags.
    function currentPhase(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (Phase) {
        Bounty storage b = bounties[bountyId];
        if (b.finalized) return Phase.Finalized;
        if (block.timestamp < b.commitDeadline) return Phase.Commit;
        if (block.timestamp < b.revealDeadline) return Phase.Reveal;
        return Phase.Judging;
    }

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
                commitDeadline: b.commitDeadline,
                revealDeadline: b.revealDeadline,
                judged: b.judged,
                finalized: b.finalized,
                commitmentCount: b.commitmentCount,
                revealedCount: b.revealedList.length,
                winnerIndex: b.winnerIndex,
                aiReview: b.aiReview
            });
    }

    function getCommitment(
        uint256 bountyId,
        address submitter
    )
        external
        view
        bountyExists(bountyId)
        returns (bytes32 hash, bool exists, bool revealed)
    {
        Commitment storage c = bounties[bountyId].commitments[submitter];
        return (c.hash, c.exists, c.revealed);
    }

    function getRevealedCount(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (uint256) {
        return bounties[bountyId].revealedList.length;
    }

    function getRevealedSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer)
    {
        Bounty storage b = bounties[bountyId];
        require(index < b.revealedList.length, "invalid index");
        Revealed storage r = b.revealedList[index];
        return (r.submitter, r.answer);
    }
}
