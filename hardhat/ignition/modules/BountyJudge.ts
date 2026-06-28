import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("BountyJudgeModule", (m) => {
  const bountyJudge = m.contract("BountyJudge");

  return { bountyJudge };
});
