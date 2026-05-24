// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DamanBenevolence} from "../src/DamanBenevolence.sol";
import {DamanReputationRegistry} from "../src/DamanReputationRegistry.sol";

/// @notice Sibling-proxy deployer for DamanBenevolence + an extended
///         DamanReputationRegistry instance that includes the
///         permissionless `register` + `lastActivity` surface.
///
/// Why sibling: the existing reputation-registry proxy at
/// `0xAA1a021215322FbB775c6Cc08d81347864a7Ac94` is owned by the
/// shared Timelock (24h delay). Upgrading it in-place to the
/// extended implementation requires scheduling a Timelock proposal
/// and waiting through the delay window. To avoid blocking the
/// agent-credit ship on the timelock window, this script deploys
/// a fresh proxy of the same contract at a new address. The
/// existing registry continues serving DamanCopyBond rulings; the
/// new sibling registry serves DamanBenevolence eligibility. Both
/// can be unified later by either upgrading the original in-place
/// or by adding the sibling as a second recorder source on
/// DamanCopyBond via Timelock proposal.
///
/// Flow:
///   1. Deploy the extended DamanReputationRegistry impl + proxy.
///      Admin = deployer EOA (so we can finalize wiring); owner =
///      Timelock. No recorder set on this sibling (it is read-only
///      from DamanBenevolence's perspective; self-register and
///      lastActivity updates happen on user-submitted txs).
///   2. Deploy DamanBenevolence impl + proxy. Owner = Timelock,
///      pauser = Safe. Initialize wires USDC + the new sibling
///      registry.
///   3. Transfer registry admin to Timelock so governance is
///      under the multisig from the script's end.
///   4. Verify on-chain that both proxies are Timelock-owned.
///   5. Log addresses for persistence to .deployments + situation.
contract DeployBenevolence is Script {
    function run() external {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address safe = vm.envAddress("SAFE_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");

        console2.log("deployer EOA:", deployer);
        console2.log("Safe multisig:", safe);
        console2.log("Timelock:", timelock);
        console2.log("USDC:", usdc);

        vm.startBroadcast();

        // 1. Sibling reputation-registry. Admin = deployer (one-shot
        //    transferAdmin to Timelock at the end of this script).
        DamanReputationRegistry repImpl = new DamanReputationRegistry();
        DamanReputationRegistry registry = DamanReputationRegistry(
            address(
                new ERC1967Proxy(
                    address(repImpl),
                    abi.encodeCall(
                        DamanReputationRegistry.initialize,
                        (deployer, int256(1), int256(-2), timelock)
                    )
                )
            )
        );
        console2.log("Sibling ReputationRegistry impl:", address(repImpl));
        console2.log("Sibling ReputationRegistry proxy:", address(registry));

        // 2. Benevolence. Owner = Timelock, pauser = Safe.
        DamanBenevolence benImpl = new DamanBenevolence();
        DamanBenevolence benevolence = DamanBenevolence(
            address(
                new ERC1967Proxy(
                    address(benImpl),
                    abi.encodeCall(
                        DamanBenevolence.initialize,
                        (usdc, address(registry), timelock, safe)
                    )
                )
            )
        );
        console2.log("DamanBenevolence impl:", address(benImpl));
        console2.log("DamanBenevolence proxy:", address(benevolence));

        // 3. Hand registry admin off to Timelock.
        registry.transferAdmin(timelock);

        vm.stopBroadcast();

        // 4. Ownership verification.
        require(benevolence.owner() == timelock, "benevolence owner is not Timelock");
        require(registry.owner() == timelock, "sibling registry owner is not Timelock");
        require(registry.admin() == timelock, "sibling registry admin is not Timelock");

        console2.log("--- Ownership verified. ---");
        console2.log("Persist these addresses:");
        console2.log("  damanBenevolence.proxy:", address(benevolence));
        console2.log("  damanBenevolence.impl:", address(benImpl));
        console2.log("  agentRegistry.proxy:", address(registry));
        console2.log("  agentRegistry.impl:", address(repImpl));
    }
}
