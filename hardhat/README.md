# BountyJudge contracts (Hardhat 3 + viem)

Solidity for the Privacy-Preserving AI Bounty Judge. See the repo root
[`README.md`](../README.md) for the full lifecycle and
[`ARCHITECTURE.md`](../ARCHITECTURE.md) for the design.

## Contracts

| File | Purpose |
| --- | --- |
| `contracts/BountyJudge.sol` | Required track: commit-reveal bounty judge |
| `contracts/RitualBountyJudge.sol` | Advanced track: TEE-encrypted hidden submissions |
| `contracts/AIJudge.sol` | Original (flawed) public-submission version, kept for reference |
| `contracts/utils/PrecompileConsumer.sol` | Ritual precompile addresses + `_executePrecompile` |

## Test

```shell
npx hardhat test            # all tests
npx hardhat test solidity   # Solidity unit tests only (.t.sol)
```

Expected: **39 passing** (`BountyJudge.t.sol` 29 incl. a 256-run fuzz test,
`RitualBountyJudge.t.sol` 10). The Ritual LLM precompile (`0x0802`) is not present
on the local EVM, so `judgeAll` is mocked with `vm.mockCall`; every commit-reveal
path runs on-chain unmocked.

## Deploy

The Ignition module `ignition/modules/BountyJudge.ts` deploys `BountyJudge`.

```shell
# local simulated chain
npx hardhat ignition deploy ignition/modules/BountyJudge.ts

# Ritual testnet (chainId 1979) - set the deployer key first
npx hardhat keystore set DEPLOYER_PRIVATE_KEY
npx hardhat ignition deploy --network ritual ignition/modules/BountyJudge.ts
```

The `ritual` network is configured in `hardhat.config.ts`
(`https://rpc.ritualfoundation.org`). Get testnet funds from
`https://faucet.ritualfoundation.org`.

---

This project uses Hardhat 3 with the native Node.js test runner (`node:test`) and
[`viem`](https://viem.sh/). Solidity tests live in `*.t.sol` files; TypeScript
integration tests would live in `test/`. To learn more about Hardhat 3, see the
[Getting Started guide](https://hardhat.org/docs/getting-started#getting-started-with-hardhat-3).
