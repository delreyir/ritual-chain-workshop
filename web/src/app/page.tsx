"use client";

import { useCallback, useEffect, useState } from "react";
import { WalletConnect } from "@/components/WalletConnect";
import { CreateBountyForm } from "@/components/CreateBountyForm";
import { LoadBountyPanel } from "@/components/LoadBountyPanel";
import { BountyView } from "@/components/BountyView";
import { useRecentBounties } from "@/hooks/useRecentBounties";
import { isContractConfigured, contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { shortenAddress } from "@/lib/format";
import { Notice } from "@/components/ui";

export default function Home() {
  const [selectedId, setSelectedId] = useState<bigint | null>(null);
  const { ids, add } = useRecentBounties();

  // Track any opened bounty in the recent list too. `add` is a no-op when the
  // id is already most-recent, so this won't loop.
  useEffect(() => {
    if (selectedId !== null) add(selectedId);
  }, [selectedId, add]);

  const handleCreated = useCallback(
    (id: bigint) => {
      add(id);
      setSelectedId(id);
    },
    [add],
  );

  return (
    <div className="min-h-full">
      {/* Top nav */}
      <header className="sticky top-0 z-10 border-b border-white/10 bg-black/50 backdrop-blur-xl">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-4 py-3 sm:px-6">
          <div className="flex items-center gap-2.5">
            <div className="grid h-9 w-9 place-items-center rounded-xl bg-gradient-to-br from-violet-500 to-fuchsia-500 text-sm font-bold text-white shadow-lg shadow-violet-500/30">
              ⟡
            </div>
            <div>
              <h1 className="text-sm font-semibold leading-tight">Ritual Bounty Judge</h1>
              <p className="text-[11px] leading-tight text-zinc-500">commit · reveal · judge on {ritualChain.name}</p>
            </div>
          </div>
          <WalletConnect />
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-4 py-6 sm:px-6">
        {/* Hero / explanation */}
        <section className="mb-6">
          <h2 className="text-3xl font-semibold tracking-tight sm:text-4xl">
            <span className="bg-gradient-to-r from-violet-300 via-fuchsia-300 to-cyan-300 bg-clip-text text-transparent">
              Sealed bounties, judged by AI.
            </span>
          </h2>
          <p className="mt-3 max-w-2xl text-sm text-zinc-400">
            Participants commit a hash of their answer first. Answers stay hidden until the reveal
            phase, so nobody can copy a rival. After reveals close, Ritual AI judges every revealed
            answer in one batch and the owner finalizes the winner.
          </p>
          <div className="mt-4 flex flex-wrap gap-2 text-xs text-zinc-300">
            <span className="inline-flex items-center gap-1.5 rounded-full bg-white/[0.04] px-3 py-1 ring-1 ring-inset ring-white/10">
              <span className="h-1.5 w-1.5 rounded-full bg-violet-400" /> Commit-reveal hides answers until judging
            </span>
            <span className="inline-flex items-center gap-1.5 rounded-full bg-white/[0.04] px-3 py-1 ring-1 ring-inset ring-white/10">
              <span className="h-1.5 w-1.5 rounded-full bg-fuchsia-400" /> All revealed answers judged in one AI call
            </span>
            <span className="inline-flex items-center gap-1.5 rounded-full bg-white/[0.04] px-3 py-1 ring-1 ring-inset ring-white/10">
              <span className="h-1.5 w-1.5 rounded-full bg-cyan-400" /> AI advises, the owner finalizes
            </span>
          </div>
        </section>

        {!isContractConfigured && (
          <div className="mb-6">
            <Notice tone="amber">
              No contract address configured. Copy <code className="font-mono">.env.example</code>{" "}
              to <code className="font-mono">.env.local</code> and set{" "}
              <code className="font-mono">NEXT_PUBLIC_CONTRACT_ADDRESS</code> to start interacting
              on-chain.
            </Notice>
          </div>
        )}

        {/* Dashboard: create + load */}
        <section className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <CreateBountyForm onCreated={handleCreated} />
          <LoadBountyPanel selectedId={selectedId} onSelect={setSelectedId} recentIds={ids} />
        </section>

        {/* Selected bounty */}
        {selectedId !== null && (
          <section className="mt-6">
            <BountyView bountyId={selectedId} />
          </section>
        )}

        <footer className="mt-10 border-t border-white/10 pt-4 text-xs text-zinc-600">
          {contractAddress ? (
            <>
              Contract <span className="font-mono">{shortenAddress(contractAddress, 6)}</span> ·
              Chain {ritualChain.id}
            </>
          ) : (
            <>Workshop demo · {ritualChain.name}</>
          )}
        </footer>
      </main>
    </div>
  );
}
