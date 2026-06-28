"use client";

import type { Bounty } from "@/lib/bounty";
import { getBountyPhase, PHASE_META } from "@/lib/bounty";
import { useNow } from "@/hooks/useNow";
import { shortenAddress, formatReward, formatTimestamp, formatRelative } from "@/lib/format";
import { Card, CardHeader, CardBody, Badge, Stat } from "@/components/ui";

export function BountyDetail({
  bountyId,
  bounty,
  isOwner,
}: {
  bountyId: bigint;
  bounty: Bounty;
  isOwner: boolean;
}) {
  const now = useNow();
  const phase = getBountyPhase(bounty, now);
  const meta = PHASE_META[phase];

  return (
    <Card>
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            <span className="font-mono text-zinc-500">#{bountyId.toString()}</span>
            <span className="normal-case text-base text-zinc-100">
              {bounty.title || "Untitled"}
            </span>
          </span>
        }
        action={
          <div className="flex items-center gap-2">
            {isOwner && <Badge tone="indigo">You own this</Badge>}
            <Badge tone={meta.tone}>{meta.label}</Badge>
          </div>
        }
      />
      <CardBody className="space-y-4">
        <div>
          <div className="text-[11px] uppercase tracking-wide text-zinc-500">Rubric</div>
          <p className="mt-1 whitespace-pre-wrap break-words text-sm text-zinc-200">
            {bounty.rubric || "-"}
          </p>
        </div>

        <div className="grid grid-cols-2 gap-2">
          <Stat label="Reward" value={formatReward(bounty.reward)} />
          <Stat label="Owner" value={shortenAddress(bounty.owner)} />
          <Stat label="Commitments" value={bounty.commitmentCount.toString()} />
          <Stat label="Revealed" value={bounty.revealedCount.toString()} />
          <Stat
            label="Commit closes"
            value={
              <span>
                {formatTimestamp(bounty.commitDeadline)}
                <span className="ml-1 text-xs text-zinc-500">
                  ({formatRelative(bounty.commitDeadline)})
                </span>
              </span>
            }
          />
          <Stat
            label="Reveal closes"
            value={
              <span>
                {formatTimestamp(bounty.revealDeadline)}
                <span className="ml-1 text-xs text-zinc-500">
                  ({formatRelative(bounty.revealDeadline)})
                </span>
              </span>
            }
          />
        </div>

        {bounty.finalized && (
          <div className="rounded-xl bg-emerald-500/10 px-3 py-2 text-sm text-emerald-200 ring-1 ring-inset ring-emerald-500/30">
            Finalized, winner is revealed submission{" "}
            <span className="font-mono font-semibold">#{bounty.winnerIndex.toString()}</span>.
          </div>
        )}
      </CardBody>
    </Card>
  );
}
