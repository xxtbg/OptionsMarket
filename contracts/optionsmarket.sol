pragma solidity >=0.8.0 <0.9.0;
pragma experimental ABIEncoderV2;

//Required libs
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

//Options Market Contract
contract Core is  ReentrancyGuard {
    using SafeMath for uint256;
    fallback() external payable { }
    mapping (address => bool) public tokenActivated;

    //currently DAI is the stablecoin of choice and the address cannot be edited by anyone to prevent users unable to complete their option trade cycles under any circumstance. If the DAI address changes, a new contract should be used by users.
    address public daiTokenAddress = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    IERC20 daiToken = IERC20(daiTokenAddress);

    //mappings for sellers and buyers of options (database)
    mapping(address=> mapping(address=> mapping(bool=> mapping(uint256=>mapping(uint256=> mapping(uint256=>uint256)))))) public orderbook;
    mapping(address=> mapping(address=>mapping(bool=> mapping(uint256=>mapping(uint256=>uint256))))) public positions;

    //Incrementing identifiers for orders. This number will be the last offer or purchase ID
    uint256 lastOrderId=0;
    uint256 lastPurchaseId =0;

    //All events based on major function executions (purchase, offers, exersizes and cancellations)
    event OptionPurchase(address buyer, address seller, address token, bool isCallOption, uint256 strikePrice, uint256 premium, uint256 expiry, uint256 amountPurchasing, uint256 purchaseId);
    event OptionOffer(address seller, address token, bool isCallOption, uint256 strikePrice, uint256 premium, uint256 expiry, uint256 amountSelling, uint256 orderId);
    event OptionExcersize(uint256 optionId, uint256 excersizeCost, uint256 timestamp);

   //Structures of offers and purchases
    struct optionOffer {
        address seller;
        address token;
        bool isCallOption;
        uint256 strikePrice;
        uint256 premium;
        uint256 expiry;
        uint256 amountUnderlyingToken;
        uint256 offeredTimestamp;
        bool isStillValid;
    }
    struct optionPurchase {
        address buyer;
        address seller;
        address token;
        bool isCallOption;
        uint256 strikePrice;
        uint256 premium;
        uint256 expiry;
        uint256 amountUnderlyingToken;
        uint256 offerId;
        uint256 purchasedTimestamp;
        bool exercized;
    }

    //publicly available data for all purchases and sale offers
    mapping (uint256 => optionPurchase) public optionPurchases;
    mapping (uint256 => optionOffer) public optionOffers;


    //Allows anyone to attempt to excersize an option after its excersize date. This can be done by a bot of the service provider or the user themselves
    function excersizeOption(uint256 purchaseId) public returns (bool){

        require(optionPurchases[purchaseId].exercized== false, "This option has already been excersized");
        require(optionPurchases[purchaseId].expiry >= block.timestamp, "This option has not reached its excersize timestamp yet");
        optionPurchase memory opData = optionPurchases[purchaseId];
        address underlyingAddress  = opData.token;
        IERC20 underlyingToken = IERC20(underlyingAddress);
        uint256 amountDAIToPay = opData.amountUnderlyingToken.mul(opData.strikePrice);
        require(daiToken.transferFrom(opData.buyer, opData.seller, amountDAIToPay), "Did the buyer approve this contract to handle DAI or have anough DAI to excersize?");
        underlyingToken.transfer(opData.buyer, opData.amountUnderlyingToken);
        optionPurchases[purchaseId].exercized= true;
        emit OptionExcersize(purchaseId, amountDAIToPay, block.timestamp);
        return true;

    }

    //This allows for the excersizing of many options with a single transaction
    function excersizeOptions(uint256[] memory purchaseIds) public returns (bool){
        for(uint i = 0; i<purchaseIds.length; i++){
            excersizeOption(purchaseIds[i]);
        }
        return true;
    }

    //This allows a user or smart contract to create a sell option order that anyone else can fill (completely or partially)
    function sellOption(address seller, address token, bool isCallOption, uint256 strikePrice, uint256 premium, uint256 expiry, uint256 amountUnderlyingToken) public returns(uint256 orderIdentifier){
        IERC20 underlyingToken = IERC20(token);
        uint256 contractBalanceBeforeTransfer = underlyingToken.balanceOf(address(this));
        underlyingToken.transferFrom(msg.sender, address(this), amountUnderlyingToken);
        uint256 contractBalanceAfterTransfer = underlyingToken.balanceOf(address(this));
        require(contractBalanceAfterTransfer >= (contractBalanceBeforeTransfer.add(amountUnderlyingToken)), "Could not transfer the amount from msg.sender that was requested");
        if(orderbook[seller][token][isCallOption][strikePrice][premium][expiry] ==0){
            orderbook[seller][token][isCallOption][strikePrice][premium][expiry] = amountUnderlyingToken;
        }
        else{
            orderbook[seller][token][isCallOption][strikePrice][premium][expiry] = orderbook[seller][token][isCallOption][strikePrice][premium][expiry].add(amountUnderlyingToken);
        }
        lastOrderId = lastOrderId.add(1);
        emit OptionOffer( seller, token, isCallOption, strikePrice, premium, expiry, amountUnderlyingToken, lastOrderId);
        return lastOrderId;
    }

    //This allows a user to immediately purchase an option based on the seller and offer information
    function buyOptionByExactPremiumAndExpiry(address buyer, address seller, address token, bool isCallOption, uint256 strikePrice, uint256 premium, uint256 expiry, uint256 amountPurchasing ) public returns (bool){
        bool optionIsBuyable = isOptionBuyable(seller, token, isCallOption, strikePrice, premium, expiry, amountPurchasing);
        require(optionIsBuyable, "This option is not buyable. Please check the seller's offer information");
        require(optionIsBuyable, "Sorry: there is no one selling options that meet your specifications. Perhaps try buyOptionByIds");
        uint256 amountSelling = orderbook[seller][token][isCallOption][strikePrice][premium][expiry];
        require(amountPurchasing <= amountSelling," There is not enough inventory for this order");
        uint256 orderSize = premium.mul(amountPurchasing);
        require(daiToken.transferFrom(msg.sender, seller, orderSize), "Please ensure that you have approved this contract to handle your DAI (error)");
        orderbook[seller][token][isCallOption][strikePrice][premium][expiry].sub(amountPurchasing);
        positions[buyer][token][isCallOption][strikePrice][expiry].add(amountPurchasing);
        lastPurchaseId = lastPurchaseId.add(1);
        emit OptionPurchase(buyer, seller, token, isCallOption, strikePrice, premium, expiry, amountPurchasing, lastPurchaseId);
        return true;
    }

    //This allows a seller to concel all or the remainder of an option offer and redeem their underlying. A seller cannot redeem the tokens that are needed by a user who already has purchased part of the offer
    function cancelOptionOffer(uint256 offerId) public returns(bool){
        //msg.sender is seller
        require(optionOffers[offerId].seller == msg.sender, "The msg.sender has to be the seller");
        uint256 amountUnderlyingToReturn = orderbook[msg.sender][optionOffers[offerId].token][optionOffers[offerId].isCallOption][optionOffers[offerId].strikePrice][optionOffers[offerId].premium][optionOffers[offerId].expiry];
        address underlyingAddress  = optionOffers[offerId].token;
        IERC20 underlyingToken = IERC20(underlyingAddress);
        underlyingToken.transfer(msg.sender, amountUnderlyingToReturn);
        orderbook[msg.sender][optionOffers[offerId].token][optionOffers[offerId].isCallOption][optionOffers[offerId].strikePrice][optionOffers[offerId].premium][optionOffers[offerId].expiry]= 0;
        optionOffers[offerId].isStillValid = false;
        return true;

    }

    //This allows a user to know if an option is purchasable based on the seller and offer information
    function isOptionBuyable(address seller, address token, bool isCallOption, uint256 strikePrice, uint256 premium, uint256 expiry, uint256 amountPurchasing) public view returns (bool){
        if(orderbook[seller][token][isCallOption][strikePrice][premium][expiry] >=amountPurchasing){
            return true;
        }
        else{
            return false;
        }
    }
}
