// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DamanCopyBond} from "../src/DamanCopyBond.sol";
import {DamanBountyAccrual} from "../src/DamanBountyAccrual.sol";
import {DamanReputationRegistry} from "../src/DamanReputationRegistry.sol";
import {DamanBondYieldVault} from "../src/DamanBondYieldVault.sol";

/// @notice Atomic deployer for the Daman contract surface on Arc
///         testnet.
///
/// Flow:
///   1. Deploy the TimelockController (Safe address from env is the
///      proposer + executor + admin).
///   2. Deploy each UUPS implementation.
///   3. Deploy each ERC1967 proxy pointing at its implementation;
///      pass the TimelockController as initial owner to every
///      `initialize` call.
///   4. Wire copy-bond as the recorder on the reputation registry
///      (the registry's admin starts as the deployer EOA so this
///      one wiring call works; afterward, admin is transferred to
///      the Timelock).
///   5. Verify on-chain that every proxy's owner is the
///      TimelockController, not the deployer EOA. Halt if not.
///
/// The deployer EOA never holds owner authority on any deployed
/// proxy past this script. If the script halts halfway, partial
/// deployments stay live but with TimelockController ownership;
/// re-running the script deploys fresh proxies (it does not adopt
/// previously-deployed ones, by design).
///
/// The Safe multisig itself is deployed out-of-band (via the Safe
/// CLI / web app) before this script runs. The Safe address is
/// passed in via the SAFE_ADDRESS env var. The Safe is the only
/// proposer / executor on the Timelock; the deployer EOA has no
/// Timelock authority.
contract DeployDaman is Script {
    /// @notice Mandatory env: deployer private key + Safe + chain config.
    /// @dev    PRIVATE_KEY, SAFE_ADDRESS, USDC_ADDRESS,
    ///         REFUND_PROTOCOL_ADDRESS, MESSAGE_TRANSMITTER_ADDRESS,
    ///         UNIVERSE_REGISTRY_ADDRESS, ARBITER_ADDRESS, ORACLE_ADDRESS,
    ///         TREASURY_ADDRESS, TIMELOCK_DELAY_SECONDS (default 86400).
    function run() external {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address safe = vm.envAddress("SAFE_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address refundProtocol = vm.envAddress("REFUND_PROTOCOL_ADDRESS");
        address messageTransmitter = vm.envAddress("MESSAGE_TRANSMITTER_ADDRESS");
        address universeRegistry = vm.envAddress("UNIVERSE_REGISTRY_ADDRESS");
        address arbiter_ = vm.envAddress("ARBITER_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY_SECONDS", uint256(86400));

        console2.log("deployer EOA:", deployer);
        console2.log("Safe multisig:", safe);
        console2.log("Timelock delay (s):", timelockDelay);

        vm.startBroadcast();

        // 1. Deploy TimelockController. Safe is the proposer + executor + admin.
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;
        TimelockController timelock = new TimelockController(timelockDelay, proposers, executors, safe);
        console2.log("Timelock:", address(timelock));

        // 2 + 3. Deploy each impl, then a proxy pointing at it. The
        //         TimelockController is the initial owner on every
        //         proxy. The deployer EOA is the initial admin on
        //         the reputation registry only (because the registry
        //         needs setRecorder called after copy-bond deploys);
        //         admin transfers to the Timelock at the end of the
        //         script via transferAdmin.

        DamanBountyAccrual bountyImpl = new DamanBountyAccrual();
        DamanBountyAccrual bountyAccrual = DamanBountyAccrual(address(new ERC1967Proxy(
            address(bountyImpl),
            abi.encodeCall(DamanBountyAccrual.initialize, (usdc, address(timelock)))
        )));
        console2.log("BountyAccrual impl:", address(bountyImpl));
        console2.log("BountyAccrual proxy:", address(bountyAccrual));

        DamanReputationRegistry repImpl = new DamanReputationRegistry();
        DamanReputationRegistry reputationRegistry = DamanReputationRegistry(address(new ERC1967Proxy(
            address(repImpl),
            abi.encodeCall(
                DamanReputationRegistry.initialize,
                (deployer, int256(1), int256(-2), address(timelock))
            )
        )));
        console2.log("ReputationRegistry impl:", address(repImpl));
        console2.log("ReputationRegistry proxy:", address(reputationRegistry));

        DamanBondYieldVault vaultImpl = new DamanBondYieldVault();
        DamanBondYieldVault bondYieldVault = DamanBondYieldVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(DamanBondYieldVault.initialize, (usdc, address(timelock)))
        )));
        console2.log("BondYieldVault impl:", address(vaultImpl));
        console2.log("BondYieldVault proxy:", address(bondYieldVault));

        DamanCopyBond bondImpl = new DamanCopyBond();
        DamanCopyBond bond = DamanCopyBond(address(new ERC1967Proxy(
            address(bondImpl),
            abi.encodeCall(DamanCopyBond.initialize, (DamanCopyBond.InitParams({
                fiatToken: usdc,
                universe: universeRegistry,
                refundProtocol: refundProtocol,
                arbiter_: arbiter_,
                oracle_: oracle,
                treasury_: treasury,
                bountyAccrual_: address(bountyAccrual),
                reputationRegistry_: address(reputationRegistry),
                messageTransmitter_: messageTransmitter,
                bondLockupSeconds_: 7 days,
                disputeWindowSeconds_: 1 days,
                initialOwner: address(timelock)
            })))
        )));
        console2.log("DamanCopyBond impl:", address(bondImpl));
        console2.log("DamanCopyBond proxy:", address(bond));

        // 4. Wire copy-bond as the sole reputation recorder, then
        //    transfer admin to the Timelock so the registry is
        //    fully under multisig governance.
        reputationRegistry.setRecorder(address(bond));
        reputationRegistry.transferAdmin(address(timelock));

        vm.stopBroadcast();

        // 5. Ownership verification. The script does not have a way
        //    to revert past broadcast; what we can do is fail
        //    loudly if the owner is not the Timelock. The caller
        //    inspects the script output and re-runs after fixing.
        require(bond.owner() == address(timelock), "copy-bond owner is not Timelock");
        require(bountyAccrual.owner() == address(timelock), "bounty owner is not Timelock");
        require(reputationRegistry.owner() == address(timelock), "reputation owner is not Timelock");
        require(bondYieldVault.owner() == address(timelock), "vault owner is not Timelock");
        require(reputationRegistry.admin() == address(timelock), "reputation admin is not Timelock");

        console2.log("--- Ownership verified. Timelock controls every Daman proxy. ---");
        console2.log("Persist these addresses to .deployments/arc-testnet.json:");
        console2.log("  timelock:", address(timelock));
        console2.log("  bountyAccrual.proxy:", address(bountyAccrual));
        console2.log("  reputationRegistry.proxy:", address(reputationRegistry));
        console2.log("  bondYieldVault.proxy:", address(bondYieldVault));
        console2.log("  damanCopyBond.proxy:", address(bond));
    }
}
