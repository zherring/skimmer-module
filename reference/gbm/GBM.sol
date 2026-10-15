// SPDX-License-Identifier: UNLICENSED
// © Copyright 2021. Patent pending. All rights reserved. Perpetual Altruism Ltd.
pragma solidity ^0.8.24;

import "./IGBM.sol";
import "./IGBMInitiator.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IZoraCreator1155} from "./interfaces/IZoraCreator1155.sol";
// import {IZoraCreator1155} from "@zoralabs/zora-1155-contracts/src/interfaces/IZoraCreator1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title GBM auction contract
/// @dev See GBM.auction on how to use this contract
/// @author Guillaume Gonnaud and Javier Fraile
contract GBM is Ownable, ReentrancyGuard, IGBM, IERC165 {

    // Struct used to store the representation of an NFT being auctioned
    struct token_representation {
        address contractAddress; // The contract address
        uint256 tokenID; // The ID of the token on the contract
        uint256 editionTokenID; // The ID of the edition token to issue bidders
        bytes4 tokenKind; // The ERC name of the token implementation bytes4(keccak256("ERC721")) or bytes4(keccak256("ERC1155"))
        uint256 tokenAmount; // Amount of token units under auction
    }

    struct Auction {
        uint256 dueIncentives;         // _auctionID => dueIncentives
        uint256 debt;                  // _auctionID => unsettled debt
        address highestBidder;         // _auctionID => bidder
        uint256 highestBid;            // _auctionID => bid
        bool biddingAllowed;           // tokenContract => Allow to start/pause ongoing auctions

        uint256 startTime;             // _auctionID => timestamp
        uint256 endTime;               // _auctionID => timestamp
        uint256 hammerTimeDuration;    // _auctionID => duration in seconds
        uint256 bidDecimals;           // _auctionID => bidDecimals
        uint256 stepMin;               // _auctionID => stepMin
        uint256 incMin;                // _auctionID => minimal earned incentives
        uint256 incMax;                // _auctionID => maximal earned incentives
        uint256 bidMultiplier;         // _auctionID => bid incentive growth multiplier
    }

    struct Collection {
        uint256 startTime;
        uint256 endTime;
        uint256 hammerTimeDuration;
        uint256 bidDecimals;
        uint256 stepMin;
        uint256 incMin; // minimal earned incentives
        uint256 incMax; // maximal earned incentives
        uint256 bidMultiplier; // bid incentive growth multiplier
        bool biddingAllowed; // Allow to start/pause ongoing auctions
    }

    // Contract address storing the ERC20 currency used in auctions

    mapping(uint256 => token_representation) internal tokenMapping; // _auctionID => token_primaryKey
    mapping(address => mapping(bytes4 => mapping(uint256 => mapping(uint256 => uint256)))) auctionMapping; // contractAddress => tokenKind => tokenID => TokenIndex => _auctionID

    mapping(address => Collection) collections;
    mapping(uint256 => bool) claimed; // _auctionID => claimed Boolean preventing multiple claim of a token

    mapping(uint256 => Auction) auctions;

    // For security reason, only non-smart contracts can receive instant incentives and proceeds in native currency. Smart contracts have to withdraw().
    mapping (address => uint256) smartContractsUsersNativeCurrencyBalance;

    address public beneficiary;

    address public editionBeneficiary;

    address public editionContract;

    constructor(address initialOwner, address initialBeneficiary, address initialEditionBeneficiary, address _editionContract, address initialContract, address initialInitiator)
        Ownable()
    {
        transferOwnership(initialOwner);
        setBeneficiary(initialBeneficiary);
        setEditionBeneficiary(initialEditionBeneficiary);
        setEditionContract(_editionContract);
        registerAnAuctionContract(initialContract, initialInitiator);
        setBiddingAllowed(initialContract, true);
    }

    // /**
    //  * @dev Returns the address of the current owner.
    //  */
    // function owner() public view virtual override(Ownable, IGBM) returns (address) {
    //     return super.owner();
    // }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Register the beneficiary of auctions
    /// @param _beneficiary The beneficiary's address
    function setBeneficiary(address _beneficiary) public onlyOwner {
        beneficiary = _beneficiary;
    }

    /// @notice Register the edition beneficiary of auctions
    /// @param _editionBeneficiary The edition beneficiary's address
    function setEditionBeneficiary(address _editionBeneficiary) public onlyOwner {
        editionBeneficiary = _editionBeneficiary;
    }

    /// @notice Register an edition contract to issue to bidders
    /// @param _contract The edition token contract
    function setEditionContract(address _contract) public onlyOwner {
        editionContract = _contract;
    }

    function setEditionTokenId(uint256 _auctionID, uint256 _editionTokenID) public onlyOwner {
        tokenMapping[_auctionID].editionTokenID = _editionTokenID;
    }

    /// @notice Place a GBM bid for a GBM auction
    /// @param _auctionID The auction you want to bid on
    /// @param _bidAmount The amount of the ERC20 token the bid is made of. They should be withdrawable by this contract.
    /// @param _highestBid The current highest bid. Throw if incorrect.
    /// @param _bidder The address the bid is being made by.
    function bid(uint256 _auctionID, uint256 _bidAmount, uint256 _highestBid, address _bidder) external payable nonReentrant() {
        require(_bidder != address(0x0), "bid: _bidder does not exist");
        require(tokenMapping[_auctionID].contractAddress != address(0x0), "bid: auctionID does not exist");
        require(collections[tokenMapping[_auctionID].contractAddress].biddingAllowed, "bid: bidding is currently not allowed");

        require(_bidAmount > 1, "bid: _bidAmount cannot be 0");
        require(_highestBid == auctions[_auctionID].highestBid, "bid: current highest bid do not match the submitted transaction _highestBid");

        // An auction start time of 0 also indicate the auction has not been created at all
        require(getAuctionStartTime(_auctionID) <= block.timestamp && getAuctionStartTime(_auctionID) != 0, "bid: Auction has not started yet");
        require(getAuctionEndTime(_auctionID) >= block.timestamp, "bid: Auction has already ended");

        require(_bidAmount > _highestBid, "bid: _bidAmount must be higher than _highestBid");
        require((_highestBid * (getAuctionBidDecimals(_auctionID) + getAuctionStepMin(_auctionID))) <= (_bidAmount * getAuctionBidDecimals(_auctionID)),
            "bid: _bidAmount must meet the minimum bid"
        );

        // Transfer the money of the bidder to the GBM smart contract
        require(msg.value == _bidAmount, "The bid amount doesn't match the amount of currency sent");

        // Extend the duration time of the auction if we are close to the end
        if (getAuctionEndTime(_auctionID) < block.timestamp + getHammerTimeDuration(_auctionID)) {
            auctions[_auctionID].endTime = block.timestamp + getHammerTimeDuration(_auctionID);
            emit Auction_EndTimeUpdated(_auctionID, auctions[_auctionID].endTime);
        }

        // Saving incentives for later sending
        uint256 duePay = auctions[_auctionID].dueIncentives;
        address previousHighestBidder = auctions[_auctionID].highestBidder;
        uint256 previousHighestBid = auctions[_auctionID].highestBid;

        // Emitting the event sequence
        if (previousHighestBidder != address(0)) {
            emit Auction_BidRemoved(_auctionID, previousHighestBidder, previousHighestBid);
        }

        if (duePay != 0) {
            auctions[_auctionID].debt = auctions[_auctionID].debt + duePay;
            emit Auction_IncentivePaid(_auctionID, previousHighestBidder, duePay);
        }

        emit Auction_BidPlaced(_auctionID, _bidder, _bidAmount);

        // Calculating incentives for the new bidder
        auctions[_auctionID].dueIncentives = calculateIncentives(_auctionID, _bidAmount);

        // Setting the new bid/bidder as the highest bid/bidder
        auctions[_auctionID].highestBidder = _bidder;
        auctions[_auctionID].highestBid = _bidAmount;

        if ((previousHighestBid + duePay) != 0) {
            // Refunding the previous bid as well as sending the incentives
            sendbaseCurrency(previousHighestBidder, previousHighestBid + duePay);
        }

        // Issue an edition to the bidder
        uint256 editionTokenId = tokenMapping[_auctionID].editionTokenID;
        if (editionTokenId != 0 && IERC1155(editionContract).balanceOf(_bidder, editionTokenId) == 0) {
            IZoraCreator1155(editionContract).adminMint(_bidder, editionTokenId, 1, "0x");
        }
    }

    /// @notice Attribute a token to the winner of the auction and distribute the proceeds to the owner of this contract.
    /// throw if bidding is disabled or if the auction is not finished.
    /// @param _auctionID The auctionID of the auction to complete
    function _claim(uint256 _auctionID) internal {
        address _ca = tokenMapping[_auctionID].contractAddress;
        // uint256 _tid = tokenMapping[_auctionID].tokenID;

        require(_ca != address(0x0), "claim: auctionID does not exist");
        require(collections[_ca].biddingAllowed, "claim: Claiming is currently not allowed");
        require(getAuctionEndTime(_auctionID) < block.timestamp, "claim: Auction has not yet ended");

        require(!claimed[_auctionID], "claim: this auction has already been claimed");
        claimed[_auctionID] = true;

        if (auctions[_auctionID].highestBid == 0) {
            // auctions[_auctionID].highestBidder = Ownable(_ca).owner();
            auctions[_auctionID].highestBidder = owner();
        }

        // Transfer the proceeds to the beneficiary
        uint256 finalAmount = auctions[_auctionID].highestBid - auctions[_auctionID].debt;
        require(beneficiary != address(0), "Beneficiary address not set");

        (bool success, ) = beneficiary.call{value: finalAmount}("");

        require(success, "Failed to send final amount");

        emit Auction_Claimed(_auctionID);
    }

    /// @notice Attribute a token to the winner of the auction and distribute the proceeds to the owner of this contract.
    /// throw if bidding is disabled or if the auction is not finished.
    /// @param _auctionID The auctionID of the auction to complete
    function claim(uint256 _auctionID) external nonReentrant() {
        _claim(_auctionID);
    }

    /// @notice Claim multiple auctions
    /// @param _auctionIDs The auctionIDs of the auctions to complete
    function claimMultiple(uint256[] calldata _auctionIDs) external nonReentrant() {
        for (uint i = 0; i < _auctionIDs.length; i++) {
            _claim(_auctionIDs[i]);
        }
    }

    /// @notice Register an auction contract default parameters for a GBM auction. To use to save gas
    /// @param _contract The token contract the auctioned token belong to
    /// @param _initiator Set to 0 if you want to use the default value registered for the token contract
    function registerAnAuctionContract(address _contract, address _initiator) public onlyOwner {
        collections[_contract].hammerTimeDuration = IGBMInitiator(_initiator).getHammerTimeDuration(uint256(uint160(_contract)));
        collections[_contract].bidDecimals = IGBMInitiator(_initiator).getBidDecimals(uint256(uint160(_contract)));
        collections[_contract].stepMin = IGBMInitiator(_initiator).getStepMin(uint256(uint160(_contract)));
        collections[_contract].incMin = IGBMInitiator(_initiator).getIncMin(uint256(uint160(_contract)));
        collections[_contract].incMax = IGBMInitiator(_initiator).getIncMax(uint256(uint160(_contract)));
        collections[_contract].bidMultiplier = IGBMInitiator(_initiator).getBidMultiplier(uint256(uint160(_contract)));
    }

    /// @notice Allow/disallow bidding and claiming for a whole token contract address.
    /// @param _contract The token contract the auctioned token belong to
    /// @param _value True if bidding/claiming should be allowed.
    function setBiddingAllowed(address _contract, bool _value) public onlyOwner {
        collections[_contract].biddingAllowed = _value;
    }

    /// @notice Register an auction token and emit the relevant Auction_Initialized & Auction_StartTimeUpdated events
    /// Throw if the token owner is not the GBM smart contract/supply of auctioned 1155 token is insufficient
    /// @param _contract The token contract the auctioned token belong to
    /// @param _tokenID The token ID of the token being auctioned
    /// @param _startTime Timestamp at which the auction will start accepting bids
    /// @param _endTime Earliest timestamp at which the auction will stop accepting bids
    /// @param _editionTokenID The edition token ID.
    function registerAnAuctionTokenSongAdao(
        address _contract,
        uint256 _tokenID,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _editionTokenID
    ) public onlyOwner {
        _registerAuctionDataSongAdao(_contract, _tokenID, _startTime, _endTime, _editionTokenID);
    }

    /// @notice Modify the auction of a token
    /// Throw if the token owner is not the GBM smart contract/supply of auctioned 1155 token is insufficient
    /// @param _auctionID ID of the auction to modify
    /// @param _initiator Set to 0 if you want to use the default value registered for the token contract (if wanting to reset to default,
    /// use an initiator sending back 0 on it's getters)
    /// @param _startTime Timestamp at which the auction will start accepting bids
    /// @param _endTime Earliest timestamp at which the auction will stop accepting bids
    function modifyAnAuctionTokenSongAdao(uint256 _auctionID, address _initiator, uint256 _startTime, uint256 _endTime) public onlyOwner {
        address _ca = tokenMapping[_auctionID].contractAddress;

        require(_ca != address(0), "modifyAnAuctionToken: Auction ID is not correct");
        // require(auctions[_auctionID].startTime > block.timestamp, "modifyAnAuctionToken: Auction has already started");
        require(_initiator != address(0), "modifyAnAuctionToken: Initiator address is not correct");

        auctions[_auctionID].startTime = _startTime;
        auctions[_auctionID].endTime = _endTime;
        auctions[_auctionID].hammerTimeDuration = IGBMInitiator(_initiator).getHammerTimeDuration(_auctionID);
        auctions[_auctionID].bidDecimals = IGBMInitiator(_initiator).getBidDecimals(_auctionID);
        auctions[_auctionID].stepMin = IGBMInitiator(_initiator).getStepMin(_auctionID);
        auctions[_auctionID].incMin = IGBMInitiator(_initiator).getIncMin(_auctionID);
        auctions[_auctionID].incMax = IGBMInitiator(_initiator).getIncMax(_auctionID);
        auctions[_auctionID].bidMultiplier = IGBMInitiator(_initiator).getBidMultiplier(_auctionID);

        require(auctions[_auctionID].startTime > 0, "modifyAnAuctionToken: Start time is not correct");
    }

    /// @notice Register an auction token and emit the relevant Auction_Initialized & Auction_StartTimeUpdated events
    /// Throw if the token owner is not the GBM smart contract/supply of auctioned 1155 token is insufficient
    /// @param _contract The token contract the auctioned token belong to
    /// @param _tokenID The token ID of the token being auctioned
    /// @param _startTime Timestamp at which the auction will start accepting bids
    /// @param _endTime Earliest timestamp at which the auction will stop accepting bids
    function _registerAuctionDataSongAdao(
        address _contract,
        uint256 _tokenID,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _editionTokenID
    ) internal {
        require(auctionMapping[_contract][bytes4(keccak256("ERC721"))][_tokenID][0] == 0, "registerAuctionData: The auction already exist for the specified token");

        // Building the auction object
        token_representation memory newAuction;
        newAuction.contractAddress = _contract;
        newAuction.tokenID = _tokenID;
        newAuction.editionTokenID = _editionTokenID;
        newAuction.tokenKind = bytes4(keccak256("ERC721"));

        uint256 auctionId;

        // Don't use block.number because it makes testing difficult.
        // auctionId = uint256(keccak256(abi.encodePacked(_contract, _tokenID, bytes4(keccak256("ERC721")), block.number)));
        auctionId = uint256(keccak256(abi.encodePacked(_contract, _tokenID, bytes4(keccak256("ERC721")))));

        auctionMapping[_contract][bytes4(keccak256("ERC721"))][_tokenID][0] = auctionId;

        tokenMapping[auctionId] = newAuction; // _auctionID => token_primaryKey

        auctions[auctionId].startTime =_startTime;
        auctions[auctionId].endTime = _endTime;

        // Event emitted when an auction is being setup
        emit Auction_Initialized(auctionId, _tokenID, _contract, bytes4(keccak256("ERC721")));

        // Event emitted when the start time of an auction changes (due to admin interaction)
        emit Auction_StartTimeUpdated(auctionId, getAuctionStartTime(auctionId));
    }

    function getAuctionHighestBidder(uint256 _auctionID) external view returns(address) {
        return auctions[_auctionID].highestBidder;
    }

    function getAuctionHighestBid(uint256 _auctionID) external view returns(uint256) {
        return auctions[_auctionID].highestBid;
    }

    function getAuctionDebt(uint256 _auctionID) external view returns(uint256) {
        return auctions[_auctionID].debt;
    }

    function getAuctionDueIncentives(uint256 _auctionID) external view returns(uint256) {
        return auctions[_auctionID].dueIncentives;
    }

    function getAuctionIDSongADao(address _contract, uint256 _tokenID) public view returns(uint256) {
        return auctionMapping[_contract][bytes4(keccak256("ERC721"))][_tokenID][0];
    }

    function getAuctionID(address _contract, bytes4, uint256 _tokenID, uint256) external view returns(uint256) {
        return getAuctionIDSongADao(_contract, _tokenID);
    }

    function getTokenKind(uint256 _auctionID) external view returns(bytes4) {
        return tokenMapping[_auctionID].tokenKind;
    }

    function getTokenId(uint256 _auctionID) external view returns(uint256) {
        return tokenMapping[_auctionID].tokenID;
    }

    function getEditionTokenId(uint256 _auctionID) external view returns(uint256) {
        return tokenMapping[_auctionID].editionTokenID;
    }

    function getTokenAmount(uint256) external pure returns(uint256){
        return 1;
    }

    function getContractAddress(uint256 _auctionID) external view returns(address) {
        return tokenMapping[_auctionID].contractAddress;
    }

    function getAuctionStartTime(uint256 _auctionID) public view returns(uint256) {
        if (auctions[_auctionID].startTime != 0) {
            return auctions[_auctionID].startTime;
        } else {
            return collections[tokenMapping[_auctionID].contractAddress].startTime;
        }
    }

    function getAuctionEndTime(uint256 _auctionID) public view returns(uint256) {
        if (auctions[_auctionID].endTime != 0) {
            return auctions[_auctionID].endTime;
        } else {
            return collections[tokenMapping[_auctionID].contractAddress].endTime;
        }
    }

    function getHammerTimeDuration(uint256 _auctionID) public view returns(uint256) {
        if (auctions[_auctionID].hammerTimeDuration != 0) {
            return auctions[_auctionID].hammerTimeDuration;
        } else {
            return collections[tokenMapping[_auctionID].contractAddress].hammerTimeDuration;
        }
    }

    function getAuctionBidDecimals(uint256 _auctionID) public view returns(uint256) {
        if (auctions[_auctionID].bidDecimals != 0) {
            return auctions[_auctionID].bidDecimals;
        } else {
            return collections[tokenMapping[_auctionID].contractAddress].bidDecimals;
        }
    }

    function getAuctionStepMin(uint256 _auctionID) public view returns(uint256) {
        if (auctions[_auctionID].stepMin != 0) {
            return auctions[_auctionID].stepMin;
        } else {
            return collections[tokenMapping[_auctionID].contractAddress].stepMin;
        }
    }

    function getAuctionIncMin(uint256 _auctionID) public view returns(uint256) {
        if (auctions[_auctionID].incMin != 0) {
            return auctions[_auctionID].incMin;
        } else {
            return collections[tokenMapping[_auctionID].contractAddress].incMin;
        }
    }

    function getAuctionIncMax(uint256 _auctionID) public view returns(uint256) {
        if (auctions[_auctionID].incMax != 0) {
            return auctions[_auctionID].incMax;
        } else {
            return collections[tokenMapping[_auctionID].contractAddress].incMax;
        }
    }

    function getAuctionBidMultiplier(uint256 _auctionID) public view returns(uint256) {
        if (auctions[_auctionID].bidMultiplier != 0) {
            return auctions[_auctionID].bidMultiplier;
        } else {
            return collections[tokenMapping[_auctionID].contractAddress].bidMultiplier;
        }
    }

    /// @notice Calculating and setting how much payout a bidder will receive if outbid
    /// @dev Only callable internally
    function calculateIncentives(uint256 _auctionID, uint256 _newBidValue) internal view returns (uint256) {
        uint256 bidDecimals = getAuctionBidDecimals(_auctionID);
        uint256 bidIncMax = getAuctionIncMax(_auctionID);

        // Init the baseline bid we need to perform against
        uint256 baseBid = auctions[_auctionID].highestBid * (bidDecimals + getAuctionStepMin(_auctionID)) / bidDecimals;

        // If no bids are present, set a baseBid value of 1 to prevent divide by 0 errors
        if (baseBid == 0) {
            baseBid = 1;
        }

        // Ratio of newBid compared to expected minBid
        uint256 decimaledRatio = ((bidDecimals * getAuctionBidMultiplier(_auctionID) * (_newBidValue - baseBid) ) / baseBid) + getAuctionIncMin(_auctionID) * bidDecimals;

        if (decimaledRatio > (bidDecimals * bidIncMax)) {
            decimaledRatio = bidDecimals * bidIncMax;
        }

        return (_newBidValue * decimaledRatio) / (bidDecimals * bidDecimals);
    }

    /// @notice Function to be used by smart contracts to collect their currency
    function withdraw(address _withdrawer) external nonReentrant() {
        (bool succ, ) = _withdrawer.call{value: smartContractsUsersNativeCurrencyBalance[_withdrawer] }("");
        require(succ, "Transfer failed");
        smartContractsUsersNativeCurrencyBalance[_withdrawer] = 0;
    }

    function getWithdrawBalance(address account) external view returns(uint256) {
        return smartContractsUsersNativeCurrencyBalance[account];
    }

    function sendbaseCurrency(address to, uint256 amount) internal {
        // For security reasons, smart contract do not get to receive instantly the currency. They have to withdraw it in a separate transaction.
        if (isContract(to)) {
            // A smart contract could pass as a normal wallet at constructor time, but I fail to see any use for this exploit in our case : the worst damage you could do is prevent yourself from bidding.
            // Once other transactions get processed eg: new bids, auction settling, etc... the smart contract will be recognized as such.
            smartContractsUsersNativeCurrencyBalance[to] += amount;
        } else {
            (bool succ, ) = to.call{value: amount }("");
            require(succ, "Transfer failed on a normal wallet. Je beg your pardon ?");
        }
    }

    function isContract(address addr) internal view returns (bool) {
        uint size;
        assembly { size := extcodesize(addr) }
        return size > 0;
    }

    /// @notice Check if an auction has been claimed or not.
    /// @param _auctionID The auctionID of the auction to check
    function wasClaimed(uint256 _auctionID) external view returns(bool) {
        return claimed[_auctionID] == true;
    }
}
