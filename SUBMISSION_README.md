# Privacy-Preserving AI Bounty Judge

This submission refines the workshop's `AIJudge` contract. In the original
version every submission was stored in plaintext on-chain during the submission
window, so anyone could read a rival's answer, improve on it, and submit the
better version. This defeats the point of a bounty.

The fix is to keep answers hidden until judging. Two tracks are implemented:

| Track | Contract | Idea |
| --- | --- | --- |
| Required | `contracts/BountyJudge.sol` | Commit-reveal on any EVM chain |
| Advanced | `contracts/RitualBountyJudge.sol` | Ritual-native, TEE-encrypted answers + one batched LLM judging call |

Original (flawed) reference contract is left untouched at `contracts/AIJudge.sol`.

---

## Required Track: commit-reveal lifecycle

```
 createBounty                submitCommitment            revealAnswer                judgeAll            finalizeWinner
 (owner escrows reward)  ->  (participants post hash) ->  (participants reveal)  ->  (AI batch judge) ->  (owner pays winner)
        |                          |                            |                         |                     |
   sets two deadlines       COMMIT phase                  REVEAL phase             JUDGING phase          FINALIZED
   commitDeadline,          ts < commitDeadline       commitDeadline <= ts         ts >= revealDeadline
   revealDeadline                                      < revealDeadline
```

### 1. `createBounty(title, rubric, commitDuration, revealDuration)` — payable
The owner escrows the reward (`msg.value`) and sets two windows:
`commitDeadline = now + commitDuration` and
`revealDeadline = commitDeadline + revealDuration`.

### 2. `submitCommitment(bountyId, commitment)`
During the commit phase, each participant posts **only** a hash:

```
commitment = keccak256(abi.encode(answer, salt, msg.sender, bountyId))
```

The plaintext answer never leaves the participant's machine yet. One commitment
per address; the empty hash is rejected.

Binding the hash to `msg.sender` **and** `bountyId` is what makes it safe: even
if a `(answer, salt)` pair leaks, nobody else can replay it (their address
differs) and it cannot be reused on another bounty.

### 3. `revealAnswer(bountyId, answer, salt)`
After `commitDeadline` (submissions are now closed) and before `revealDeadline`,
participants reveal. The contract recomputes the hash from `(answer, salt,
msg.sender, bountyId)` and accepts the answer only if it matches the commitment
that address posted earlier. Valid reveals are appended to the eligible list.

Because the commit window is already closed when reveals start, you cannot watch
a rival reveal and then submit a copy — there is no open submission slot left.

### 4. `judgeAll(bountyId, llmInput)` — owner only
Once the reveal window closes, the owner sends one Ritual LLM precompile request
(`0x0802`) that contains the rubric and **all** revealed answers in a single
prompt, so the model judges the whole batch in one call. The AI's review/ranking
is stored on-chain in `aiReview`.

### 5. `finalizeWinner(bountyId, winnerIndex)` — owner only
The owner finalizes the winning index (informed by the AI review) and the
escrowed reward is paid out. Uses checks-effects-interactions plus a
`nonReentrant` guard.

### Helper / view functions
- `computeCommitment(answer, salt, submitter, bountyId)` — reproduce the exact
  hash off-chain / in the frontend.
- `currentPhase(bountyId)` — `Commit | Reveal | Judging | Finalized`.
- `getBounty`, `getCommitment`, `getRevealedCount`, `getRevealedSubmission`.

---

## Advanced Track (summary)

`RitualBountyJudge.sol` removes the reveal step entirely: answers are
ECIES-encrypted to a Ritual TEE executor, only ciphertext is stored on-chain,
and a single `judgeAll` call decrypts + judges the whole batch **inside the
enclave**. See `ARCHITECTURE.md` for the full data-flow and trust model.

---

## Project layout (changes in this submission)

```
hardhat/contracts/BountyJudge.sol           Required track (commit-reveal)
hardhat/contracts/BountyJudge.t.sol         Solidity tests (29 cases + fuzz)
hardhat/contracts/RitualBountyJudge.sol     Advanced track (TEE / encrypted)
hardhat/contracts/RitualBountyJudge.t.sol   Solidity tests (7 cases)
hardhat/ignition/modules/BountyJudge.ts     Deployment module
ARCHITECTURE.md                             Architecture note (both tracks)
TEST_PLAN.md                                Test plan for reveal cases
REFLECTION.md                               Reflection answer
```

## How to run

```bash
cd hardhat
npm install              # repo ships a pnpm-lock.yaml; npm works too
npx hardhat build        # compile (solc 0.8.24)
npx hardhat test solidity
```

Expected: **36 passing** (29 for `BountyJudge`, including a 256-run fuzz test,
and 7 for `RitualBountyJudge`).

### Deploy

```bash
# local
npx hardhat ignition deploy ignition/modules/BountyJudge.ts
# Ritual testnet (needs DEPLOYER_PRIVATE_KEY config var)
npx hardhat ignition deploy --network ritual ignition/modules/BountyJudge.ts
```

## A note on the AI judging call in tests

The LLM precompile at `0x0802` exists only on Ritual Chain, not on the local
simulated EVM. The tests therefore mock it with `vm.mockCall`, returning the
same async envelope the real precompile produces:
`abi.encode(simmedInput, abi.encode(hasError, completionData, modelMetadata,
errorMessage, convoHistory))`. The commit-reveal logic itself runs fully
on-chain with no mocking.
