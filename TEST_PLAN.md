# Test Plan

Tests are Solidity unit tests (`forge-std`) run by Hardhat 3:

```bash
cd hardhat && npx hardhat test solidity
```

Result: **39 passing** — `contracts/BountyJudge.t.sol` (29, incl. a 256-run
fuzz test) and `contracts/RitualBountyJudge.t.sol` (10).

The Ritual LLM precompile (`0x0802`) is not present on the local EVM, so
`judgeAll` is exercised with `vm.mockCall`, returning the exact async envelope
the real precompile emits. Every commit-reveal path runs on-chain unmocked.

---

## Required Track — reveal cases (the focus of the assignment)

| # | Test | Scenario | Expected |
| --- | --- | --- | --- |
| 1 | `test_reveal_validRevealSucceeds` | correct `answer + salt` from the committer | reveal stored, `revealed = true`, appears in list |
| 2 | `test_reveal_wrongSaltReverts` | right answer, wrong salt | revert `reveal mismatch` |
| 3 | `test_reveal_wrongAnswerReverts` | right salt, tampered answer | revert `reveal mismatch` |
| 4 | `test_reveal_wrongSenderCannotStealCommitment` | a different address tries to reveal someone else's `(answer, salt)` | revert `reveal mismatch` (hash bound to `msg.sender`) |
| 5 | `test_reveal_revertsWithoutCommitment` | address never committed | revert `no commitment` |
| 6 | `test_reveal_revertsBeforeRevealPhase` | reveal during commit window | revert `reveal not started` |
| 7 | `test_reveal_revertsAfterRevealDeadline` | reveal after the reveal deadline | revert `reveal phase closed` |
| 8 | `test_reveal_revertsOnDoubleReveal` | same address reveals twice | revert `already revealed` |
| 9 | `test_reveal_answerTooLongReverts` | answer over `MAX_ANSWER_LENGTH` | revert `answer too long` |

## Commit phase

| # | Test | Expected |
| --- | --- | --- |
| 10 | `test_submitCommitment_works` | stores hash, emits `CommitmentSubmitted` |
| 11 | `test_submitCommitment_revertsAfterDeadline` | revert `commit phase closed` |
| 12 | `test_submitCommitment_revertsOnDoubleCommit` | revert `already committed` |
| 13 | `test_submitCommitment_revertsOnEmptyCommitment` | revert `empty commitment` |
| 14 | `test_submitCommitment_revertsOnUnknownBounty` | revert `bounty not found` |

## Bounty creation & phase machine

| # | Test | Expected |
| --- | --- | --- |
| 15 | `test_createBounty_storesFields` | owner, reward, deadlines, defaults |
| 16 | `test_createBounty_revertsWithoutReward` | revert `reward required` |
| 17 | `test_currentPhase_progression` | `Commit -> Reveal -> Judging` as time advances |

## Judging (`judgeAll`, LLM mocked)

| # | Test | Expected |
| --- | --- | --- |
| 18 | `test_judgeAll_happyPath` | `judged = true`, `aiReview` stored |
| 19 | `test_judgeAll_revertsBeforeRevealClosed` | revert `reveal not finished` |
| 20 | `test_judgeAll_revertsForNonOwner` | revert `not bounty owner` |
| 21 | `test_judgeAll_revertsWithNoReveals` | committed-but-not-revealed → revert `no revealed answers` |
| 22 | `test_judgeAll_revertsOnDoubleJudge` | revert `already judged` |

## Payout (`finalizeWinner`)

| # | Test | Expected |
| --- | --- | --- |
| 23 | `test_finalizeWinner_paysWinner` | winner balance += reward, `finalized`, `winnerIndex`, reward zeroed, event |
| 24 | `test_finalizeWinner_revertsBeforeJudged` | revert `not judged yet` |
| 25 | `test_finalizeWinner_revertsForNonOwner` | revert `not bounty owner` |
| 26 | `test_finalizeWinner_revertsOnInvalidIndex` | revert `invalid winner` |
| 27 | `test_finalizeWinner_revertsOnDoubleFinalize` | revert `already finalized` |

## Commitment helper

| # | Test | Expected |
| --- | --- | --- |
| 28 | `test_computeCommitment_matchesManualEncoding` | matches `keccak256(abi.encode(...))` |
| 29 | `testFuzz_computeCommitment_deterministic` | same inputs → same hash (256 random runs) |

---

## Advanced Track — `RitualBountyJudge`

| # | Test | Expected |
| --- | --- | --- |
| 1 | `test_submitEncrypted_storesCiphertextOnly` | ciphertext + commitment stored, not plaintext |
| 2 | `test_submitEncrypted_revertsAfterDeadline` | revert `submissions closed` |
| 3 | `test_submitEncrypted_revertsOnDoubleSubmit` | revert `already submitted` |
| 4 | `test_judgeAll_batchHappyPath` | one mocked batched call → `judged`, `aiReview` |
| 5 | `test_judgeAll_revertsWhileOpen` | revert `submissions still open` |
| 6 | `test_auditSubmission_verifiesCommitment` | wrong pair reverts; correct pair flags `audited` |
| 7 | `test_finalizeWinner_paysWinner` | winner paid, `finalized`, `winnerIndex` |
| 8 | `test_publishRevealedBundle_storesRefAndHash` | after judging, `revealedAnswersRef` + `revealedAnswersHash` stored |
| 9 | `test_publishRevealedBundle_revertsBeforeJudged` | revert `not judged yet` |
| 10 | `test_publishRevealedBundle_revertsForNonOwner` | revert `not bounty owner` |

---

## Manual / on-network checks (not in CI)

These require the real Ritual testnet (LLM precompile + funded `RitualWallet`):

- Fund `RitualWallet` for the owner, build a real `llmInput` with the rubric +
  revealed answers, call `judgeAll`, and confirm the returned `aiReview` decodes
  to a sensible ranking.
- For the advanced track, encrypt answers with `eciesjs` to the executor public
  key from `TEEServiceRegistry`, submit ciphertext, and confirm the TEE-side
  decryption + batch judging round-trips.
