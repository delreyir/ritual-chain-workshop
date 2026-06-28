import {
  keccak256,
  encodePacked,
  toHex,
  type Address,
} from "viem";

/**
 * Commit-reveal helpers for BountyJudge.
 *
 * The commitment must match the contract exactly:
 *   keccak256(abi.encodePacked(answer, salt, submitter, bountyId))
 */

export function computeCommitment(
  answer: string,
  salt: `0x${string}`,
  submitter: Address,
  bountyId: bigint,
): `0x${string}` {
  return keccak256(
    encodePacked(
      ["string", "bytes32", "address", "uint256"],
      [answer, salt, submitter, bountyId],
    ),
  );
}

/** Cryptographically-random 32-byte salt. */
export function randomSalt(): `0x${string}` {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return toHex(bytes);
}

// --- Local persistence of (answer, salt) between commit and reveal ----------
//
// The reveal step needs the exact answer + salt used at commit time. We keep
// them in localStorage, scoped by chain + bounty + submitter, so a participant
// can come back later and reveal with one click. This is convenience only: the
// data never needs to leave the browser, and losing it just means re-typing the
// answer and pasting the salt manually.

export type RevealData = { answer: string; salt: `0x${string}` };

function key(chainId: number, bountyId: bigint, submitter: Address): string {
  return `bountyjudge:reveal:${chainId}:${bountyId.toString()}:${submitter.toLowerCase()}`;
}

export function saveRevealData(
  chainId: number,
  bountyId: bigint,
  submitter: Address,
  data: RevealData,
): void {
  try {
    localStorage.setItem(key(chainId, bountyId, submitter), JSON.stringify(data));
  } catch {
    /* ignore quota / private mode */
  }
}

export function loadRevealData(
  chainId: number,
  bountyId: bigint,
  submitter: Address,
): RevealData | null {
  try {
    const raw = localStorage.getItem(key(chainId, bountyId, submitter));
    if (!raw) return null;
    const parsed = JSON.parse(raw) as RevealData;
    if (typeof parsed.answer === "string" && /^0x[0-9a-fA-F]{64}$/.test(parsed.salt)) {
      return parsed;
    }
    return null;
  } catch {
    return null;
  }
}

export function clearRevealData(
  chainId: number,
  bountyId: bigint,
  submitter: Address,
): void {
  try {
    localStorage.removeItem(key(chainId, bountyId, submitter));
  } catch {
    /* ignore */
  }
}
