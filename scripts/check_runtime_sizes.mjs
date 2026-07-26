import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const EIP170_LIMIT = 24_576;
const RUNTIME_BUDGET = 24_000;
const contracts = [
  ["ArbHook", "../foundry/out/ArbHook.sol/ArbHook.json"],
  ["ArbitrageLogic", "../foundry/out/ArbitrageLogic.sol/ArbitrageLogic.json"],
  [
    "AaveV3ERC3156Adapter",
    "../foundry/out/AaveV3ERC3156Adapter.sol/AaveV3ERC3156Adapter.json",
  ],
];

let failed = false;
for (const [name, relativeArtifact] of contracts) {
  const artifactPath = fileURLToPath(new URL(relativeArtifact, import.meta.url));
  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  const bytecode = artifact.deployedBytecode?.object;
  if (typeof bytecode !== "string" || !bytecode.startsWith("0x")) {
    throw new Error(`Missing deployed bytecode in ${artifactPath}`);
  }

  const runtimeBytes = (bytecode.length - 2) / 2;
  const budgetMargin = RUNTIME_BUDGET - runtimeBytes;
  const eip170Margin = EIP170_LIMIT - runtimeBytes;
  console.log(
    `${name}: ${runtimeBytes} bytes ` +
      `(budget margin ${budgetMargin}, EIP-170 margin ${eip170Margin})`,
  );

  if (runtimeBytes > RUNTIME_BUDGET) failed = true;
}

if (failed) {
  console.error(`Runtime bytecode exceeds the ${RUNTIME_BUDGET}-byte project budget.`);
  process.exit(1);
}
