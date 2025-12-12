const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const SQRT_PRICE_1_1 = BigInt("79228162514264337593543950336");
const TICK_LOWER = -887220;
const TICK_UPPER = 887220;
const MIN_SQRT_RATIO = 4295128739n;
const MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342n;
const AFTER_SWAP_FLAG = 1 << 6;

async function deployIntegrationFixture() {
	const [owner] = await ethers.getSigners();

	const arbMathFactory = await ethers.getContractFactory(
		"contracts/lib/ArbMath.sol:ArbMath"
	);
	const arbMath = await arbMathFactory.deploy();

	const ArbitrageLogic = await ethers.getContractFactory("ArbitrageLogic", {
		libraries: {
			ArbMath: await arbMath.getAddress(),
		},
	});
	const arbLogic = await ArbitrageLogic.deploy();

	const DataStorage = await ethers.getContractFactory("DataStorage");
	const dataStorage = await DataStorage.deploy(owner.address);

	const PoolManager = await ethers.getContractFactory("PoolManagerHarness");
	const poolManager = await PoolManager.deploy(owner.address);

	const HookDeployer = await ethers.getContractFactory("HookDeployer");
	const hookDeployer = await HookDeployer.deploy();

	const predictedHookAddress = await hookDeployer.deployArbHook.staticCall(
		await poolManager.getAddress(),
		owner.address,
		await arbLogic.getAddress(),
		await dataStorage.getAddress(),
		AFTER_SWAP_FLAG
	);
	const tx = await hookDeployer.deployArbHook(
		await poolManager.getAddress(),
		owner.address,
		await arbLogic.getAddress(),
		await dataStorage.getAddress(),
		AFTER_SWAP_FLAG
	);
	await tx.wait();
	const arbHook = await ethers.getContractAt("ArbHook", predictedHookAddress);
	await dataStorage.setWriter(predictedHookAddress);
	await arbHook.setHookMaxIterations(1);

	const TestToken = await ethers.getContractFactory("TestToken");
	const tokenA = await TestToken.deploy("TokenA", "TKA", ethers.parseUnits("1000000", 18));
	const tokenB = await TestToken.deploy("TokenB", "TKB", ethers.parseUnits("1000000", 18));

	await tokenA.mint(owner.address, ethers.parseUnits("100000", 18));
	await tokenB.mint(owner.address, ethers.parseUnits("100000", 18));

	let token0 = tokenA;
	let token1 = tokenB;
	let currency0 = await tokenA.getAddress();
	let currency1 = await tokenB.getAddress();
	if (BigInt(currency0) > BigInt(currency1)) {
		token0 = tokenB;
		token1 = tokenA;
		currency0 = await token0.getAddress();
		currency1 = await token1.getAddress();
	}

	const PoolModifyLiquidityTest = await ethers.getContractFactory(
		"PoolModifyLiquidityTestWrapper"
	);
	const modifyHelper = await PoolModifyLiquidityTest.deploy(
		await poolManager.getAddress()
	);

	const PoolSwapTest = await ethers.getContractFactory("PoolSwapTestWrapper");
	const swapHelper = await PoolSwapTest.deploy(await poolManager.getAddress());

	const maxAllow = ethers.MaxUint256;
	await token0.approve(await modifyHelper.getAddress(), maxAllow);
	await token1.approve(await modifyHelper.getAddress(), maxAllow);
	await token0.approve(await swapHelper.getAddress(), maxAllow);
	await token1.approve(await swapHelper.getAddress(), maxAllow);

	const poolKey = {
		currency0,
		currency1,
		fee: 3000,
		tickSpacing: 60,
		hooks: predictedHookAddress,
	};

	await poolManager.initialize(poolKey, SQRT_PRICE_1_1);

	return {
		owner,
		arbHook,
		poolManager,
		modifyHelper,
		swapHelper,
		token0,
		token1,
		poolKey,
		predictedHookAddress,
	};
}

	describe("ArbHook integration", function () {
		it("triggers attemptAll after a real swap", async () => {
			const { owner, arbHook, poolManager, modifyHelper, swapHelper, token0, token1, poolKey } =
				await loadFixture(deployIntegrationFixture);

			console.log("[integration] Fixtures ready", {
				owner: owner.address,
				arbHook: await arbHook.getAddress(),
				poolManager: await poolManager.getAddress(),
				modifyHelper: await modifyHelper.getAddress(),
				swapHelper: await swapHelper.getAddress(),
				token0: await token0.getAddress(),
				token1: await token1.getAddress(),
				poolKey,
			});

			const liquidityDelta = ethers.parseUnits("500", 18);
			const modifyParams = {
			tickLower: TICK_LOWER,
			tickUpper: TICK_UPPER,
			liquidityDelta,
			salt: ethers.ZeroHash,
		};

			console.log("[integration] Adding liquidity", { modifyParams });
			await modifyHelper.modifyLiquidity(poolKey, modifyParams, "0x");
			console.log("[integration] Liquidity added");

		const swapParams = {
			zeroForOne: true,
			amountSpecified: -ethers.parseUnits("1", 18),
			sqrtPriceLimitX96: MIN_SQRT_RATIO + 1n,
		};
			const testSettings = { takeClaims: false, settleUsingBurn: false };

			console.log("[integration] About to swap", { swapParams, testSettings });
			try {
				await expect(
					swapHelper.swap(poolKey, swapParams, testSettings, "0x")
				).to.emit(arbHook, "HookAttemptAll")
					.withArgs(1, true, false);
				console.log("[integration] Swap finished successfully");
			} catch (err) {
				console.log("[integration] Swap reverted", err);
				throw err;
			}
		});
	});
