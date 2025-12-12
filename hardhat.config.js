require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

// Initialize environment variables with defaults to prevent errors if .env is missing
const PRIVATE_KEY =
	process.env.PRIVATE_KEY ||
	"0x0000000000000000000000000000000000000000000000000000000000000000";
const BASE_RPC_URL = process.env.BASE_RPC_URL || "https://mainnet.base.org";
const BASE_TESTNET_RPC_URL =
	process.env.BASE_TESTNET_RPC_URL || "https://sepolia.base.org";

const HUGE_GAS = 1_000_000_000; // 1 billion gas ≈ "infinite" for tests

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
	solidity: {
		compilers: [
			{
				version: "0.8.20",
				settings: {
					optimizer: {
						enabled: true,
						runs: 200, // Reduced from 1000 to optimize for size over gas
					},
					viaIR: true,
					evmVersion: "cancun",
					outputSelection: {
						"*": {
							"*": ["abi", "evm.bytecode"],
						},
					},
				},
			},
			{
				version: "0.8.24",
				settings: {
					optimizer: {
						enabled: true,
						runs: 200,
					},
					viaIR: true,
					evmVersion: "cancun",
				},
			},
			{
				version: "0.8.26",
				settings: {
					optimizer: {
						enabled: true,
						runs: 200,
					},
					viaIR: true,
					evmVersion: "cancun",
				},
			},
			// Additional compiler for Uniswap V3 contracts
			{
				version: "0.7.6", // Uniswap V3 uses 0.7.6
				settings: {
					optimizer: {
						enabled: true,
						runs: 1000,
					},
				},
			},
		],
	},
	networks: {
		hardhat: {
			forking: {
				// You can use Alchemy or Infura to fork Base mainnet
				url: process.env.BASE_RPC_URL || "https://mainnet.base.org",
				// set block to 33939153
				blockNumber: 33939153,
			},
			hardfork: "cancun",
			chainId: 8453,
			// Provide hardfork activation history for Base (L2). We assume modern forks since genesis
			chains: {
				8453: {
					hardforkHistory: {
						berlin: 0,
						london: 0,
						merge: 0,
						shanghai: 0,
						cancun: 0,
					},
				},
			},
			// Increase the gas limit to accommodate complex deployment
			// gas: 12000000,
			// blockGasLimit: 12000000,

			blockGasLimit: HUGE_GAS, // per-block ceiling
			gas: HUGE_GAS, // default per-tx ceiling
			allowUnlimitedContractSize: true, // if your worker byte-code grows >24 kB
		},
		base: {
			url: process.env.BASE_RPC_URL || "https://mainnet.base.org",
			accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
		},
		"base-testnet": {
			url: BASE_TESTNET_RPC_URL,
			accounts: [PRIVATE_KEY],
			chainId: 84532, // Base Sepolia testnet
		},
		"base-goerli": {
			url: "https://goerli.base.org",
			accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
		},
	},
	gasReporter: {
		enabled: process.env.REPORT_GAS === "true",
		currency: "USD",
	},
	paths: {
		sources: "./contracts",
		tests: "./test",
		cache: "./cache",
		artifacts: "./artifacts",
	},
	mocha: {
		timeout: 300000, // 5 minutes
	},
};
