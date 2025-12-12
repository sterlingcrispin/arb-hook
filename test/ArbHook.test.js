const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

async function deployHookFixture() {
	const [owner, other] = await ethers.getSigners();

	const arbMathFactory = await ethers.getContractFactory("contracts/lib/ArbMath.sol:ArbMath");
	const arbMath = await arbMathFactory.deploy();
	const ArbitrageLogic = await ethers.getContractFactory("ArbitrageLogic", {
		libraries: {
			ArbMath: await arbMath.getAddress(),
		},
	});
	const arbLogic = await ArbitrageLogic.deploy();

	const DataStorage = await ethers.getContractFactory("DataStorage");
	const dataStorage = await DataStorage.deploy(owner.address);

	const MockPoolManager = await ethers.getContractFactory("MockPoolManager");
	const mockPoolManager = await MockPoolManager.deploy();

	const ArbHook = await ethers.getContractFactory("ArbHook");
	const arbHook = await ArbHook.deploy(
		await mockPoolManager.getAddress(),
		owner.address,
		await arbLogic.getAddress(),
		await dataStorage.getAddress()
	);

	await mockPoolManager.setHook(arbHook);
	await dataStorage.setWriter(await arbHook.getAddress());

	return { owner, other, arbHook, mockPoolManager, dataStorage };
}

describe("ArbHook", function () {
	it("initializes with default hookMaxIterations", async () => {
		const { arbHook } = await loadFixture(deployHookFixture);
		expect(await arbHook.hookMaxIterations()).to.equal(2);
	});

	it("enforces owner-only setters", async () => {
		const { arbHook, other } = await loadFixture(deployHookFixture);
		await expect(
			arbHook.connect(other).setHookMaxIterations(3)
		).to.be.revertedWithCustomError(
			arbHook,
			"OwnableUnauthorizedAccount"
		);
	});

	it("runs attemptAll via afterSwap when triggered by the pool manager", async () => {
		const { arbHook, mockPoolManager, owner } = await loadFixture(
			deployHookFixture
		);
		await arbHook.connect(owner).setHookMaxIterations(1);
		await expect(mockPoolManager.triggerAfterSwap())
			.to.emit(arbHook, "HookAttemptAll")
			.withArgs(1, true, false);
	});

	it("skips execution when hookMaxIterations is zero", async () => {
		const { arbHook, mockPoolManager, owner } = await loadFixture(
			deployHookFixture
		);
		await arbHook.connect(owner).setHookMaxIterations(0);
		await expect(mockPoolManager.triggerAfterSwap()).to.not.emit(
			arbHook,
			"HookAttemptAll"
		);
	});
});
