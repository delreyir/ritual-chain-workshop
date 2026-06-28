"use client";

import { useReadContract } from "wagmi";
import bountyJudgeAbi from "@/abi/BountyJudge";
import { contractAddress, isContractConfigured } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { parseBounty, type Bounty } from "@/lib/bounty";

/** Read + parse a single bounty, polling so the phase flips as deadlines pass. */
export function useBounty(bountyId?: bigint) {
  const enabled = bountyId !== undefined && isContractConfigured;

  const query = useReadContract({
    address: contractAddress,
    abi: bountyJudgeAbi,
    functionName: "getBounty",
    args: bountyId !== undefined ? [bountyId] : undefined,
    chainId: ritualChain.id,
    query: {
      enabled,
      refetchInterval: 12_000,
    },
  });

  const bounty: Bounty | undefined = query.data
    ? parseBounty(query.data)
    : undefined;

  return {
    bounty,
    isLoading: query.isLoading,
    isError: query.isError,
    error: query.error,
    refetch: query.refetch,
  };
}
