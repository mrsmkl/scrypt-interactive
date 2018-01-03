pragma solidity ^0.4.0;

import {DepositsManager} from './DepositsManager.sol';
import {ScryptVerifier} from "./scryptVerifier.sol";
import {DogeRelay} from "./DogeRelay.sol";

// ClaimManager: queues a sequence of challengers to play with a claimant.

contract ClaimManager is DepositsManager {
    uint private numClaims = 0;     // index as key for the claims mapping.
    uint public minDeposit = 1;    // TODO: what should the minimum deposit be?

    // a claim goes through two stages after being created:
    // stage 1: new challenges are allowed.
    // stage 2: no new challenges are allowed.
    // the claim exists until all verification games are played out.
    // reasoning behind having two stages is to prevent DoS attacks;
    // i.e. a malicious adversary cannot sybil challenge a claim after challengeTimeout blocks have passed.
    uint public challengeTimeout = 20;

    // blocks to wait for callback from scryptVerifier,
    // before moving onto the next.
    // TODO: we're not using this yet.
    uint public verificationGameTimeout = 40;

    DogeRelay public dogeRelay;
    ScryptVerifier public scryptVerifier;

    event DepositBonded(uint claimID, address account, uint amount);
    event DepositUnbonded(uint claimID, address account, uint amount);
    event ClaimCreated(uint claimID, address claimant, bytes plaintext, bytes blockHash);
    event ClaimChallenged(uint claimID, address challenger);
    event ClaimVerificationGameStarted(uint claimID, address claimant, address challenger, uint sessionId);
    event ClaimDecided(uint claimID, address winner, address loser);
    event ClaimSuccessful(uint claimID, address claimant, bytes plaintext, bytes blockHash);
    event ClaimVerificationGamesEnded(uint claimID);

    struct ScryptClaim {
        uint id;
        address claimant;
        bytes plaintext;    // the plaintext Dogecoin block header.
        bytes blockHash;    // the Dogecoin blockhash.
        uint createdAt;     // the block number at which the claim was created.
        address[] challengers;      // all current challengers.
        uint numChallengers;
        uint currentChallenger;    // index of next challenger to play a verification game.
        bool verificationOngoing;   // is the claim waiting for results from an ongoing verificationg game.
        mapping (address => uint) bondedDeposits;   // all deposits bonded in this claim.
        bool decided;
    }

    mapping(uint => ScryptClaim) private claims;

    modifier onlyBy(address _account) {
        require(msg.sender == _account);
        _;
    }



    // @dev – the constructor
    function ClaimManager(DogeRelay _dogeRelay, ScryptVerifier _scryptVerifier) public {
        dogeRelay = _dogeRelay;
        scryptVerifier = _scryptVerifier;
    }

    // @dev – locks up part of the a user's deposit into a claim.
    // @param claimID – the claim id.
    // @param account – the user's address.
    // @param amount – the amount of deposit to lock up.
    // @return – the user's deposit bonded for the claim.
    function bondDeposit(uint claimID, address account, uint amount) private returns (uint) {
        ScryptClaim storage claim = claims[claimID];

        require(deposits[account] >= amount);
        deposits[account] -= amount;

        claim.bondedDeposits[account] = claim.bondedDeposits[account].add(amount);
        DepositBonded(claimID, account, amount);
        return claim.bondedDeposits[account];
    }

    // @dev – accessor for a claims bonded deposits.
    // @param claimID – the claim id.
    // @param account – the user's address.
    // @return – the user's deposit bonded for the claim.
    function getBondedDeposit(uint claimID, address account) public view returns (uint) {
        ScryptClaim storage claim = claims[claimID];
        return claim.bondedDeposits[account];
    }

    // @dev – unlocks a user's bonded deposits from a claim.
    // @param claimID – the claim id.
    // @param account – the user's address.
    // @return – the user's deposit which was unbonded from the claim.
    function unbondDeposit(uint claimID, address account) public returns (uint) {
        ScryptClaim storage claim = claims[claimID];
        require(claim.decided == true);
        uint bondedDeposit = claim.bondedDeposits[account];
        delete claim.bondedDeposits[account];
        deposits[account] = deposits[account].add(bondedDeposit);
        DepositUnbonded(claimID, account, bondedDeposit);

        return bondedDeposit;
    }

    // @dev – check whether a DogeCoin blockHash was calculated correctly from the plaintext block header.
    // only callable by the DogeRelay contract.
    // @param _plaintext – the plaintext blockHeader.
    // @param _blockHash – the blockHash.
    // @param claimant – the address of the Dogecoin block submitter.
    function checkScrypt(bytes _plaintext, bytes _blockHash, address claimant) onlyBy(dogeRelay) public returns (uint) {
        require(deposits[claimant] >= minDeposit);

        ScryptClaim storage claim = claims[numClaims];
        claim.claimant = claimant;
        claim.plaintext = _plaintext;
        claim.blockHash = _blockHash;
        claim.numChallengers = 0;
        claim.currentChallenger = 0;
        claim.verificationOngoing = false;
        claim.createdAt = block.number;
        claim.decided = false;

        bondDeposit(numClaims, claimant, minDeposit);
        ClaimCreated(numClaims, claim.claimant, claim.plaintext, claim.blockHash);

        numClaims.add(1);
        return numClaims;
    }

    // @dev – challenge an existing Scrypt claim.
    // triggers a downstream claim computation on the scryptVerifier contract
    // where the claimant & the challenger will immediately begin playing a verification.
    //
    // @param claimID – the claim ID.
    function challengeClaim(uint claimID) public {
        ScryptClaim storage claim = claims[claimID];

        // check that the claim is in Stage 1 (i.e. accepting new challenges).
        require(block.number.sub(claim.createdAt) <= challengeTimeout);

        require(deposits[msg.sender] >= minDeposit);
        bondDeposit(claimID, msg.sender, minDeposit);

        claim.challengers.push(msg.sender);
        claim.numChallengers = claim.numChallengers.add(1);
        ClaimChallenged(claimID, msg.sender);
    }

    // @dev – runs a verification game between the claimant and
    // the next queued-up challenger.
    //
    // @param claimID – the claim id.
    function runNextVerificationGame(uint claimID) public {
        ScryptClaim storage claim = claims[claimID];

        // check if there is a challenger who has not the played verificationg game yet.
        if (claim.numChallengers > claim.currentChallenger) {
            require(claim.verificationOngoing == false);

            // kick off a verification game.
            uint sessionId = scryptVerifier.claimComputation(claim.challengers[claim.currentChallenger], claim.claimant, claim.plaintext, claim.blockHash, 2050);
            ClaimVerificationGameStarted(claimID, claim.claimant, claim.challengers[claim.currentChallenger], sessionId);

            claim.verificationOngoing = true;
            claim.currentChallenger = claim.currentChallenger.add(1);
        } else {
            require(claim.verificationOngoing == false);
            claim.decided = true;
            ClaimVerificationGamesEnded(claimID);
        }
    }

    // @dev – called when a verification game has ended.
    // only callable by the scryptVerifier contract.
    //
    // @param claimID – the claim ID.
    // @param winner – winner of the verification game.
    // @param loser – loser of the verification game.
    function claimDecided(uint claimID, address winner, address loser) onlyBy(address(scryptVerifier)) public {
        ScryptClaim storage claim = claims[claimID];

        require(claim.verificationOngoing == true);
        claim.verificationOngoing = false;

        // reward the winner, with the loser's bonded deposit.
        uint depositToTransfer = claim.bondedDeposits[loser];
        delete claim.bondedDeposits[loser];
        claim.bondedDeposits[winner] = claim.bondedDeposits[winner].add(depositToTransfer);

        ClaimDecided(claimID, winner, loser);

        if (claim.claimant == loser) {
            // the claim is over.
            // note: no callback needed to the DogeRelay contract,
            // because it by default does not save blocks.

            //Trigger end of verification game
            claim.numChallengers = 0;
            runNextVerificationGame(claimID);
        } else if (claim.claimant == winner) {
            // the claim continues.
            runNextVerificationGame(claimID);
        } else { revert(); }
    }

    // @dev – check whether a claim has successfully withstood all challenges.
    // if successful, it will trigger a callback to the DogeRelay contract,
    // notifying it that the Scrypt blockhash was correctly calculated.
    //
    // @param claimID – the claim ID.
    function checkClaimSuccessful(uint claimID) public {
        ScryptClaim storage claim = claims[claimID];

        // check that the claim is in Stage w (i.e. not accepting new challenges).
        require(block.number.sub(claim.createdAt) > challengeTimeout);

        // check that there is no ongoing verification game.
        require(claim.verificationOngoing == false);

        // check that all verification games have been played.
        require(claim.numChallengers == claim.currentChallenger);

        unbondDeposit(claim.id, claim.claimant);

        dogeRelay.scryptVerified(claim.plaintext, claim.blockHash);

        ClaimSuccessful(claimID, claim.claimant, claim.plaintext, claim.blockHash);
    }

    function firstChallenger(uint claimID) public view returns(address) {
        require(claimID < numClaims);
        return claims[claimID].challengers[0];
    }

    function createdAt(uint claimID) public view returns(uint) {
        require(claimID < numClaims);
        return claims[claimID].createdAt;
    }
}