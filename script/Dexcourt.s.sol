// SPDX-License-Identifier: MTT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {AgreementEscrow} from "../src/Escrow.sol";
import {Voting} from "../src/Voting.sol";
// import {NLX} from "../src/Token.sol";

contract DexCourtScript is Script {
    Voting voting;
    AgreementEscrow escrow;
    // NLX nlx;

    address initialOwner_ = address(0x8b642A6676301134BCBEcBebA247018f293015e7);
    address feeRecipient_ = address(0x8b642A6676301134BCBEcBebA247018f293015e7);
    address _disputeResolver = address(0x8b642A6676301134BCBEcBebA247018f293015e7);
    address voteToken = address(0);

    // address disputeAdmin_ = address(0x4f023375511448Cac335F66c0fde313A50AfD066);
    // address voteToken = address(0xdF27F4f5d5247C9498682d85317b5f8187c5aE26);

    function run() external returns (Voting, AgreementEscrow) {
        vm.startBroadcast();

        // voting = new Voting(initialOwner_, feeRecipient_, disputeAdmin_);
        // address voteToken = address(
        //     new NLX(
        //         initialOwner_,
        //         "Nolox",
        //         "NLX",
        //         18,
        //         1000000 // 1 million total supply
        //     )
        // );

        voting = new Voting(initialOwner_, feeRecipient_, address(voteToken), address(_disputeResolver));

        // voting = Voting(0x5080e9ee69FeD9825fC081eEd94e4FF923c3af15);
        escrow = new AgreementEscrow(initialOwner_, feeRecipient_, address(_disputeResolver));

        // escrow = AgreementEscrow(
        //     payable(0xC8A44CF6AEae1edeFeE913cD7887Ed4e25e00a91)
        // );

        // escrow.setEscrowConfig(
        //     300, // platformFeeBP
        //     0.01 ether, // feeAmount
        //     10 minutes, // disputeDuration
        //     24 hours, // grace1Duration
        //     48 hours // grace2Duration
        // );

        // voting.setVotingConfig(
        //     10 minutes, // disputeDuration
        //     address(voteToken), // voteToken
        //     feeRecipient_, // feeRecipient
        //     address(_disputeResolver), // disputeResolver
        //     0.01 ether // feeAmount
        // );

        console.log("Deployed voting at:", address(voting));
        console.log("Deployed escrow at:", address(escrow));
        console.log("Deployed token at:", address(voteToken));
        vm.stopBroadcast();

        return (voting, escrow);
    }
}
