import type { Address } from "viem";

/**
 * Mirrors the `BountyJudge.BountyView` struct returned by `getBounty`.
 * viem decodes a single returned struct as an object keyed by its field names.
 */
export type Bounty = {
  owner: Address;
  title: string;
  rubric: string;
  reward: bigint;
  commitDeadline: bigint;
  revealDeadline: bigint;
  judged: boolean;
  finalized: boolean;
  commitmentCount: bigint;
  revealedCount: bigint;
  winnerIndex: bigint;
  aiReview: `0x${string}`;
};

/** Normalize the raw `getBounty` result (object or positional tuple) to Bounty. */
export function parseBounty(raw: unknown): Bounty {
  // viem returns a named object for a single struct return; be tolerant of a
  // positional tuple too, just in case.
  const o = raw as Record<string, unknown> & ArrayLike<unknown>;
  const at = (name: string, idx: number) =>
    (o as Record<string, unknown>)[name] ?? (o as ArrayLike<unknown>)[idx];

  return {
    owner: at("owner", 0) as Address,
    title: at("title", 1) as string,
    rubric: at("rubric", 2) as string,
    reward: at("reward", 3) as bigint,
    commitDeadline: at("commitDeadline", 4) as bigint,
    revealDeadline: at("revealDeadline", 5) as bigint,
    judged: at("judged", 6) as boolean,
    finalized: at("finalized", 7) as boolean,
    commitmentCount: at("commitmentCount", 8) as bigint,
    revealedCount: at("revealedCount", 9) as bigint,
    winnerIndex: at("winnerIndex", 10) as bigint,
    aiReview: at("aiReview", 11) as `0x${string}`,
  };
}

export type BountyPhase =
  | "commit" // accepting commitment hashes
  | "reveal" // accepting reveals, submissions closed
  | "judging" // reveal window over, awaiting AI judging
  | "judged" // AI has judged, awaiting finalization
  | "finalized";

export function getBountyPhase(b: Bounty, nowSeconds = Date.now() / 1000): BountyPhase {
  if (b.finalized) return "finalized";
  if (b.judged) return "judged";
  if (nowSeconds < Number(b.commitDeadline)) return "commit";
  if (nowSeconds < Number(b.revealDeadline)) return "reveal";
  return "judging";
}

export const PHASE_META: Record<
  BountyPhase,
  { label: string; tone: "green" | "amber" | "indigo" | "zinc" }
> = {
  commit: { label: "Commit phase", tone: "green" },
  reveal: { label: "Reveal phase", tone: "amber" },
  judging: { label: "Ready for judging", tone: "amber" },
  judged: { label: "Judged", tone: "indigo" },
  finalized: { label: "Finalized", tone: "zinc" },
};

/** Can a participant still submit a commitment? */
export function canCommit(b: Bounty, nowSeconds = Date.now() / 1000): boolean {
  return !b.judged && !b.finalized && Number(b.commitDeadline) > nowSeconds;
}

/** Is the reveal window currently open? */
export function canReveal(b: Bounty, nowSeconds = Date.now() / 1000): boolean {
  return (
    !b.judged &&
    !b.finalized &&
    Number(b.commitDeadline) <= nowSeconds &&
    Number(b.revealDeadline) > nowSeconds
  );
}
