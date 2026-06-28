# Privacy-Preserving AI Bounty Judge

Workshop submission (Ritual, 23 June 2026). This repo refines the workshop's
`AIJudge` contract, which had a critical flaw: submissions were stored in
plaintext on-chain during the submission window, so a latecomer could read a
rival's answer, improve it, and submit the better version. That rewards copying.

This submission secures the process so **answers stay hidden until judging is
complete**, in two tracks:

| Track | Contract | Idea |
| --- | --- | --- |
| Required | [`hardhat/contracts/BountyJudge.sol`](hardhat/contracts/BountyJudge.sol) | Commit-reveal, works on any EVM chain |
| Advanced | [`hardhat/contracts/RitualBountyJudge.sol`](hardhat/contracts/RitualBountyJudge.sol) | Ritual-native: TEE-encrypted answers + one batched LLM judging call |

The original (flawed) contract is left untouched at `hardhat/contracts/AIJudge.sol`
for comparison.

Companion docs: [`ARCHITECTURE.md`](ARCHITECTURE.md) ·
[`TEST_PLAN.md`](TEST_PLAN.md) · [`REFLECTION.md`](REFLECTION.md).

```
/hardhat  -> smart contracts + tests
/web      -> Next.js frontend (wired to BountyJudge / commit-reveal)
```

---

## Commit-reveal lifecycle (Required Track)

```
 createBounty               submitCommitment           revealAnswer               judgeAll           finalizeWinner
 owner escrows reward   ->  participant posts hash  ->  participant reveals    ->  AI batch judge ->  owner pays winner
        |                         |                          |                         |                    |
  commitDeadline,            COMMIT phase               REVEAL phase             JUDGING phase        FINALIZED
  revealDeadline set     ts < commitDeadline       commitDeadline <= ts          ts >= revealDeadline
                                                     < revealDeadline
```

1. **`createBounty(title, rubric, commitDuration, revealDuration)`** *(payable)* —
   escrow the reward and open two windows:
   `commitDeadline = now + commitDuration`,
   `revealDeadline = commitDeadline + revealDuration`.

2. **`submitCommitment(bountyId, commitment)`** — during the commit phase a
   participant posts only a hash:
   ```
   commitment = keccak256(abi.encode(answer, salt, msg.sender, bountyId))
   ```
   The plaintext answer never leaves their machine yet. Binding the hash to
   `msg.sender` and `bountyId` means a leaked `(answer, salt)` cannot be replayed
   by another address or reused on another bounty.

3. **`revealAnswer(bountyId, answer, salt)`** — after `commitDeadline` (submissions
   closed) and before `revealDeadline`, participants reveal. The contract
   recomputes the hash and accepts the answer only if it matches the commitment
   that same address posted. Because commits close before reveals open, you can't
   watch a rival reveal and then submit a copy.

4. **`judgeAll(bountyId, llmInput)`** *(owner only)* — after the reveal window
   closes, one Ritual LLM precompile (`0x0802`) call judges **all** revealed
   answers in a single batched prompt; the AI review/ranking is stored on-chain.

5. **`finalizeWinner(bountyId, winnerIndex)`** *(owner only)* — the owner finalizes
   the AI-recommended winner and the escrowed reward is paid (checks-effects-
   interactions + `nonReentrant`).

Helpers: `computeCommitment(...)` (reproduce the hash off-chain), `currentPhase(...)`
(`Commit | Reveal | Judging | Finalized`), and `getBounty / getCommitment /
getRevealedCount / getRevealedSubmission`.

### Advanced Track (summary)
`RitualBountyJudge` drops the reveal step: answers are ECIES-encrypted to a Ritual
TEE executor, only ciphertext is stored on-chain, and a single `judgeAll`
decrypts + judges the batch **inside the enclave**. Full data-flow, the
on-chain/off-chain split, and the trust model are in [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## Run the contracts

```bash
cd hardhat
npm install            # repo ships a pnpm-lock.yaml; npm also works
npx hardhat build      # compile (solc 0.8.24)
npx hardhat test solidity
```

Expected: **36 passing** — 29 for `BountyJudge` (incl. a 256-run fuzz test) and
7 for `RitualBountyJudge`. See [`TEST_PLAN.md`](TEST_PLAN.md) for the case matrix.

The LLM precompile (`0x0802`) only exists on Ritual Chain, so `judgeAll` is
exercised in tests with `vm.mockCall`; the commit-reveal logic runs fully on-chain
unmocked.

## Deploy

```bash
# local simulated chain
npx hardhat ignition deploy ignition/modules/BountyJudge.ts
# Ritual testnet (set the DEPLOYER_PRIVATE_KEY config var first)
npx hardhat keystore set DEPLOYER_PRIVATE_KEY
npx hardhat ignition deploy --network ritual ignition/modules/BountyJudge.ts
```

Ritual testnet: chainId `1979`, RPC `https://rpc.ritualfoundation.org`,
faucet `https://faucet.ritualfoundation.org`.

### Live deployment (Ritual testnet)

`BountyJudge` is deployed and verified live at:

```
0x8E7f047025236dF8ACC6816857f98e7c5269D3B0
```

Explorer: https://explorer.ritualfoundation.org/address/0x8E7f047025236dF8ACC6816857f98e7c5269D3B0
(`nextBountyId = 1`, `MAX_SUBMISSIONS = 50` confirm the commit-reveal contract).
Point the frontend at it via `NEXT_PUBLIC_CONTRACT_ADDRESS` in `web/.env.local`.

The full create → commit → reveal flow (including a wrong-salt rejection) was
exercised live against this deployment.

> **Ritual time unit:** Ritual Chain has sub-second blocks and its
> `block.timestamp` is in **milliseconds**, not seconds. The commit/reveal
> durations passed to `createBounty` are therefore in milliseconds on Ritual,
> and the frontend does all deadline math in ms. The contract itself is
> unit-agnostic (it only adds and compares timestamps), so it stays correct on
> any EVM chain as long as the caller uses that chain's `block.timestamp` unit.

## Run the frontend

```bash
cd web
npm install
cp .env.example .env.local   # set NEXT_PUBLIC_BOUNTY_JUDGE_ADDRESS to your deployment
npm run dev
```

The UI walks a bounty through create → commit → reveal → judge → finalize against
the deployed `BountyJudge`.
