# Architecture Note

## 1. Problem

The original `AIJudge` stored every answer as plaintext on-chain as soon as it
was submitted. Submissions are public on a blockchain by definition, so a late
participant could read all earlier answers, combine the best parts, and submit a
strictly better entry. The bounty rewards copying, not original work.

Goal: **answers must stay hidden until judging is complete**, while keeping the
process verifiable and the payout trustless.

---

## 2. Required Track — commit-reveal (`BountyJudge.sol`)

### Data model
```
Bounty
  owner, title, rubric, reward
  commitDeadline, revealDeadline
  judged, finalized, aiReview, winnerIndex
  commitments:  address => { hash, exists, revealed }   // hashes only
  revealedList: Revealed[] { submitter, answer }         // filled at reveal time
```

### Two-phase flow
1. **Commit phase** (`ts < commitDeadline`): participants store only
   `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`.
2. **Reveal phase** (`commitDeadline <= ts < revealDeadline`): participants send
   the plaintext `answer + salt`; the contract recomputes the hash and accepts
   the answer only on an exact match.
3. **Judging** (`ts >= revealDeadline`): owner triggers a single batched LLM call.
4. **Finalize**: owner pays the AI-recommended winner.

### Why it is secure
- **Hiding**: during the submission window only hashes are visible. keccak256 is
  preimage-resistant, and the `salt` defeats brute-forcing low-entropy answers.
- **Binding**: a participant cannot change their answer after committing —
  reveal must match the stored hash.
- **No copying**: the commit window closes before reveals begin, so there is no
  open slot to submit a copied answer into.
- **No identity theft**: the hash includes `msg.sender`, so a leaked
  `(answer, salt)` cannot be revealed by a different address. Including
  `bountyId` prevents cross-bounty replay.

### Where plaintext lives (Required Track)
- Off-chain on the participant's machine during the commit phase.
- On-chain **only after** the reveal phase starts (by design — once submissions
  are closed, publishing is harmless and enables transparent judging).

### Trade-off
Commit-reveal needs a second transaction and a liveness assumption: a participant
who never reveals is simply dropped from judging. This is the standard,
chain-agnostic trade-off and works on any EVM chain.

---

## 3. Advanced Track — Ritual-native hidden submissions (`RitualBountyJudge.sol`)

Here answers stay encrypted the entire time and there is **no reveal step**. We
use Ritual's TEE-backed execution: the LLM precompile (`0x0802`) runs inside a
Trusted Execution Environment, so secrets can be decrypted there without ever
appearing on-chain.

### Data model
```
Bounty
  owner, title, rubric, reward, submitDeadline
  executor              // TEE executor the answers are encrypted to
  judged, finalized, aiReview, winnerIndex
  revealedAnswersRef    // off-chain pointer to the revealed bundle (e.g. ipfs://)
  revealedAnswersHash   // keccak256 commitment to that bundle
  submissions: EncSubmission[] { submitter, encryptedAnswer, commitment, audited }
```

### Private submission flow (diagram)
```
 participant browser                 chain (RitualBountyJudge)            TEE executor (enclave)
 ───────────────────                 ──────────────────────────          ──────────────────────
 answer + salt
   │ ECIES-encrypt to executor pubkey
   │ commitment=keccak256(packed)
   ▼
 submitEncrypted(ct, commitment) ───▶ store { ct, commitment }  (only ciphertext on-chain)
                                          │
                  (owner, after deadline) │ judgeAll(llmInput with encryptedSecrets[], piiEnabled)
                                          ▼
                                      LLM precompile 0x0802 ───────────▶ decrypt ALL answers in-enclave
                                                                          run ONE batched judging prompt
                                      aiReview (ranking)  ◀───────────── signed result (TEE attested)
                                          │
                  (owner) publishRevealedBundle(ref, hash)
                                          ▼
                                      store revealedAnswersRef + revealedAnswersHash
 anyone: fetch bundle from ref ─────▶ verify keccak256(bundle) == revealedAnswersHash
                                          │
                  (owner) finalizeWinner(winnerIndex) ─▶ pay winner
```

### Flow
1. **createBounty(..., executor)** — owner picks a TEE `executor` (its public key
   comes from Ritual's `TEEServiceRegistry`, read off-chain).
2. **submitEncrypted(bountyId, encryptedAnswer, commitment)** — the participant
   ECIES-encrypts the answer to the executor's public key off-chain and submits
   the ciphertext plus an integrity commitment
   `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`.
3. **judgeAll(bountyId, llmInput)** — built off-chain, `llmInput` is a single LLM
   precompile request where:
   - `encryptedSecrets[]` carries every submission's ciphertext, named
     `{{ANSWER_0}}, {{ANSWER_1}}, ...`,
   - `messagesJson` is one prompt embedding the rubric and referencing those
     templates,
   - `piiEnabled = true` so the TEE decrypts the secrets and substitutes them
     **inside the enclave** before running the model.
   The model judges the whole batch in **one** call and returns a ranking.
4. **publishRevealedBundle(bountyId, ref, hash)** *(final reveal)* — after
   judging, the owner publishes an off-chain bundle of **all** revealed answers
   (e.g. on IPFS/Arweave) and commits to it on-chain with only
   `revealedAnswersRef` + `revealedAnswersHash`. Anyone fetches the bundle and
   checks `keccak256(bundle) == revealedAnswersHash`. Large plaintext never hits
   contract storage (the PDF's "Suggested Reveal Pattern").
5. **finalizeWinner** — owner pays the winner.
6. **auditSubmission(answer, salt)** *(optional, per-submission)* — a participant
   can also reveal their own `(answer, salt)` so anyone can verify that their
   stored ciphertext committed to that plaintext. Pure integrity check; the
   answer is not stored.

### Where plaintext answers exist
- In the participant's browser/CLI at encryption time (before submitting).
- Inside the TEE enclave during `judgeAll`, after the executor decrypts
  `encryptedSecrets`.
- **Nowhere else.** The chain, mempool, transaction receipts and event logs only
  ever contain ciphertext and a keccak commitment.

### On-chain vs off-chain

| Item | Location |
| --- | --- |
| ECIES ciphertext of each answer | on-chain |
| Integrity commitment (keccak) | on-chain |
| Submitter address, deadlines, reward | on-chain |
| AI review / ranking result | on-chain (`aiReview`) |
| Plaintext answer | off-chain (browser) + inside TEE only |
| Executor public key | off-chain (`TEEServiceRegistry`) |
| Assembled LLM request (`llmInput`) | built off-chain, passed as calldata |
| Revealed-answers bundle (plaintext) | off-chain (IPFS / Arweave / storage-ref) |
| Bundle reference + hash | on-chain (`revealedAnswersRef`, `revealedAnswersHash`) |

### How the LLM receives submissions for batch judging
One request, not one-call-per-answer. The ciphertext blobs ride in the request's
`encryptedSecrets` array; the prompt references them by template name. The TEE
decrypts all of them, the model scores them together against the rubric, and the
single completion (a ranking or winner index) is returned via the precompile
response and written to `aiReview`. Batching keeps cost bounded (one
`RitualWallet`-funded call) and lets the model compare answers against each other,
not just in isolation.

### Final reveal & on-chain commitment
The judging output is the structured shape the PDF suggests:
```json
{
  "winnerIndex": 2,
  "ranking": [{ "index": 2, "score": 94, "reason": "Best satisfies the rubric." }],
  "revealedAnswersRef": "ipfs://... or storage-ref://...",
  "revealedAnswersHash": "0x...",
  "summary": "Submission 2 is the strongest answer."
}
```
The owner publishes the full revealed-answers bundle off-chain and records only
`revealedAnswersRef` + `revealedAnswersHash` on-chain via
`publishRevealedBundle(...)`. The contract thereby **commits** to the exact
bundle without storing it: any observer fetches the bundle from the ref and
checks `keccak256(bundle) == revealedAnswersHash`. If the owner published a
different bundle than what was judged, the hash check fails, so the reveal is
tamper-evident. This satisfies "how the final reveal happens" and "how the
contract commits to the final revealed bundle" while keeping gas bounded.

### Trust model
- The executor is a registered, TEE-attested node (Ritual's `TEEServiceRegistry`
  verifies the enclave). The block builder only accepts results from a valid
  attestation, so the executor cannot fabricate the model output.
- Confidentiality reduces to the TEE: a broken enclave could in principle expose
  plaintext to the executor operator. The `auditSubmission` commitment gives
  post-hoc integrity even if you distrust the executor's confidentiality.

---

## 4. What is public, hidden, AI-decided, human-decided

| Concern | Decision |
| --- | --- |
| Bounty title, rubric, reward, deadlines | **public** (rules must be transparent) |
| Answers during submission | **hidden** (hashes or ciphertext) |
| Answers after judging | public (required track) / optional audit (advanced) |
| Who submitted what | public addresses; content hidden until allowed |
| Ranking / quality scoring of answers | **AI** (batched LLM against the rubric) |
| Final winner selection + payout | **human** owner, using the AI review as input |
| Eligibility (valid reveal, deadlines, limits) | **contract** (deterministic rules) |

The AI proposes; the human owner disposes. The contract enforces the rules that
must not depend on either (timing, commitment validity, single payout). This
split is expanded in `REFLECTION.md`.

---

## 5. Security considerations implemented
- Checks-effects-interactions + `nonReentrant` on `finalizeWinner` (external ETH
  send happens after state is flipped and reward is zeroed).
- `onlyOwner` on `judgeAll` / `finalizeWinner`; `bountyExists` on all bounty ops.
- Strict phase gating by timestamp; `MAX_SUBMISSIONS` and `MAX_ANSWER_LENGTH`
  bound gas and storage.
- Commitment bound to `(answer, salt, sender, bountyId)` to stop replay and
  identity theft.
- Empty-commitment and double-commit / double-reveal / double-finalize guards.

### Known limitations
- `judgeAll` trusts the owner to assemble an `llmInput` that faithfully includes
  every revealed/encrypted answer; a malicious owner could omit entries. A fully
  trustless version would have the contract derive the prompt from on-chain data.
- The winner index is chosen by the owner; the contract does not parse the AI
  ranking. Parsing structured AI output on-chain (e.g. via the JQ precompile) is
  a natural next step.
