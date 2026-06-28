"use client";

import { useEffect, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import bountyJudgeAbi from "@/abi/BountyJudge";
import { contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { useNow } from "@/hooks/useNow";
import { canCommit, canReveal, type Bounty } from "@/lib/bounty";
import {
  computeCommitment,
  randomSalt,
  saveRevealData,
  loadRevealData,
  clearRevealData,
} from "@/lib/commitment";
import { useWriteTx } from "@/hooks/useWriteTx";
import {
  Card,
  CardHeader,
  CardBody,
  Field,
  Input,
  Textarea,
  Button,
  TxStatus,
  Notice,
} from "@/components/ui";

const explorerBase = ritualChain.blockExplorers?.default.url;

/**
 * Participation panel for the commit-reveal flow.
 *  - Commit phase: submit only keccak256(answer, salt, you, bountyId).
 *  - Reveal phase: reveal the (answer, salt); the contract verifies the hash.
 * The (answer, salt) are stored in localStorage so reveal is one click later.
 */
export function Participate({
  bountyId,
  bounty,
  onChanged,
}: {
  bountyId: bigint;
  bounty: Bounty;
  onChanged: () => void;
}) {
  const { address, isConnected } = useAccount();
  const now = useNow();

  // Has the connected wallet committed / revealed already?
  const commitment = useReadContract({
    address: contractAddress,
    abi: bountyJudgeAbi,
    functionName: "getCommitment",
    args: address ? [bountyId, address] : undefined,
    chainId: ritualChain.id,
    query: { enabled: !!contractAddress && !!address, refetchInterval: 12_000 },
  });
  const hasCommitted = Boolean(commitment.data?.[1]);
  const hasRevealed = Boolean(commitment.data?.[2]);

  const commitTx = useWriteTx(() => {
    commitment.refetch();
    onChanged();
  });
  const revealTx = useWriteTx(() => {
    if (address) clearRevealData(ritualChain.id, bountyId, address);
    commitment.refetch();
    onChanged();
  });

  const [answer, setAnswer] = useState("");
  const [salt, setSalt] = useState<`0x${string}` | "">("");

  // Prefill the reveal form from saved commit data once we know the address.
  useEffect(() => {
    if (!address) return;
    const saved = loadRevealData(ritualChain.id, bountyId, address);
    if (saved) {
      setAnswer((a) => (a ? a : saved.answer));
      setSalt((s) => (s ? s : saved.salt));
    }
  }, [address, bountyId]);

  const inCommit = canCommit(bounty, now / 1000);
  const inReveal = canReveal(bounty, now / 1000);

  // Nothing to do outside the commit/reveal windows.
  if (!inCommit && !inReveal) return null;

  async function handleCommit(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !contractAddress || !address) return;
    const s = randomSalt();
    const commit = computeCommitment(answer.trim(), s, address, bountyId);
    try {
      await commitTx.run({
        address: contractAddress,
        abi: bountyJudgeAbi,
        functionName: "submitCommitment",
        args: [bountyId, commit],
        chainId: ritualChain.id,
      });
      // Persist for the reveal step (after the tx is sent successfully).
      saveRevealData(ritualChain.id, bountyId, address, { answer: answer.trim(), salt: s });
      setSalt(s);
    } catch {
      /* surfaced via commitTx.state */
    }
  }

  async function handleReveal(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !salt || !contractAddress) return;
    try {
      await revealTx.run({
        address: contractAddress,
        abi: bountyJudgeAbi,
        functionName: "revealAnswer",
        args: [bountyId, answer.trim(), salt as `0x${string}`],
        chainId: ritualChain.id,
      });
    } catch {
      /* surfaced via revealTx.state */
    }
  }

  // --- Commit phase UI ------------------------------------------------------
  if (inCommit) {
    return (
      <Card>
        <CardHeader
          title="Commit an answer"
          subtitle="Only a hash is posted now. Your answer stays private until you reveal it."
        />
        <CardBody>
          {hasCommitted ? (
            <Notice tone="green">
              You&apos;ve committed. Come back during the reveal phase to reveal your answer. Keep
              this browser (your answer + salt are saved locally), or note your salt:{" "}
              {salt ? <span className="break-all font-mono text-[11px]">{salt}</span> : "—"}.
            </Notice>
          ) : (
            <form onSubmit={handleCommit} className="space-y-3">
              <Field
                label="Your answer"
                hint="Hashed locally with a random salt. The plaintext is not sent yet."
              >
                <Textarea
                  value={answer}
                  onChange={(e) => setAnswer(e.target.value)}
                  rows={5}
                  placeholder="Write your submission…"
                />
              </Field>
              <Button
                type="submit"
                disabled={!isConnected || !answer.trim() || commitTx.isBusy}
                className="w-full"
              >
                {commitTx.isBusy ? "Committing…" : "Commit hash"}
              </Button>
              {!isConnected && (
                <p className="text-xs text-zinc-500">Connect your wallet to commit.</p>
              )}
              <TxStatus
                state={commitTx.state}
                error={commitTx.error}
                hash={commitTx.hash}
                explorerBase={explorerBase}
              />
            </form>
          )}
        </CardBody>
      </Card>
    );
  }

  // --- Reveal phase UI ------------------------------------------------------
  return (
    <Card>
      <CardHeader
        title="Reveal your answer"
        subtitle="Submissions are closed. Reveal the answer + salt you committed."
      />
      <CardBody>
        {!hasCommitted ? (
          <Notice tone="zinc">You didn&apos;t commit to this bounty, so there is nothing to reveal.</Notice>
        ) : hasRevealed ? (
          <Notice tone="green">Your answer has been revealed and verified. ✓</Notice>
        ) : (
          <form onSubmit={handleReveal} className="space-y-3">
            <Field label="Your answer" hint="Must match exactly what you committed.">
              <Textarea
                value={answer}
                onChange={(e) => setAnswer(e.target.value)}
                rows={5}
                placeholder="Your committed answer…"
              />
            </Field>
            <Field label="Salt" hint="Auto-filled if you committed in this browser.">
              <Input
                value={salt}
                onChange={(e) => setSalt(e.target.value as `0x${string}`)}
                placeholder="0x…"
              />
            </Field>
            <Button
              type="submit"
              disabled={!isConnected || !answer.trim() || !salt || revealTx.isBusy}
              className="w-full"
            >
              {revealTx.isBusy ? "Revealing…" : "Reveal answer"}
            </Button>
            <TxStatus
              state={revealTx.state}
              error={revealTx.error}
              hash={revealTx.hash}
              explorerBase={explorerBase}
            />
          </form>
        )}
      </CardBody>
    </Card>
  );
}
