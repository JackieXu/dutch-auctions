// SPDX-License-Identifier: MIT

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../IAuctionHouse.sol";
import "./IFungibleAuction.sol";

/// @title Auction for fungible tokens
contract FungibleAuction is IFungibleAuction {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /// @dev Only set if auction was created via the auction house factory. Used for callbacks.
    IAuctionHouse public auctionHouse;

    /// @notice Address of the contract governing the token that is being auctioned.
    IERC20 public immutable sellTokenAddress;

    /// @notice Address of the contract governing the token used to buy in this auction.
    IERC20 public immutable buyTokenAddress;

    /// @notice Creator of the auction and address auctioning their tokens.
    address public immutable auctioneer;

    /// @notice Parameters of this specific auction.
    uint256 public immutable initialAmount;
    uint256 public immutable startTimestamp;
    uint256 public immutable duration;
    uint256 public immutable maxPrice;
    uint256 public immutable minPrice;

    /// @notice The last paid price, for Dutch Auctions this is also the lowest price.
    uint256 public lowestSellPrice;

    constructor(
        IERC20 sellTokenAddress_,
        IERC20 buyTokenAddress_,
        uint256 initialAmount_,
        address auctioneer_,
        uint256 startTimestamp_,
        uint256 duration_,
        uint256 maxPrice_,
        uint256 minPrice_,
        bool isAuctionHouse
    ) {
        require(maxPrice_ >= minPrice_, "Auction: Price must go down");
        require(startTimestamp_ + duration_ >= block.timestamp, "Auction: Cannot end in the past");

        if (isAuctionHouse) {
            auctionHouse = IAuctionHouse(msg.sender);
        }

        initialAmount = initialAmount_;
        auctioneer = auctioneer_;
        sellTokenAddress = sellTokenAddress_;
        buyTokenAddress = buyTokenAddress_;
        startTimestamp = startTimestamp_;
        duration = duration_;
        maxPrice = maxPrice_;
        minPrice = minPrice_;
    }

    /// @dev Buy `amount` tokens. Will buy whatever is left if `amount` is not available in its entirety.
    function buy(uint256 amount) external override {
        require(isActive(), "Auction: not active");

        uint256 availableAmount = sellTokenAddress.balanceOf(address(this));

        require(availableAmount > 0, "Auction: sold out");

        // Allow buyer to buy whatever is left.
        if (amount > availableAmount) {
            amount = availableAmount;
        }

        // The number of tokens required to buy the requested amount (or what is left of it).
        uint256 buyPrice = getPriceInBuyTokens(amount);

        require(
            buyTokenAddress.allowance(msg.sender, address(this)) >= buyPrice,
            "Auction: Auction allowance < tokensToBuy"
        );
        require(buyTokenAddress.balanceOf(msg.sender) >= buyPrice, "Auction: Bidder balance < tokensToBuy");

        // Set lowest sell price, used when closing the auction in the auction house.
        lowestSellPrice = getPrice();

        // Token transfers.
        buyTokenAddress.safeTransferFrom(msg.sender, address(this), buyPrice);
        sellTokenAddress.safeTransfer(msg.sender, amount);

        emit Buy(address(sellTokenAddress), amount, lowestSellPrice);
    }

    /// @dev Withdraw the tokens that were bid.
    /// TODO: Allow auctioneer to withdraw tokens before auction is finished, in case of long durations?
    function withdraw() external override {
        require(msg.sender == auctioneer, "Auction: only auctioneer can withdraw");

        uint256 sellTokenBalance = sellTokenAddress.balanceOf(address(this));

        // Allow withdrawal if all tokens have been sold.
        if (sellTokenBalance > 0) {
            require(startTimestamp + duration < block.timestamp, "Auction: auction has not ended yet");
        }

        buyTokenAddress.safeTransferFrom(address(this), auctioneer, buyTokenAddress.balanceOf(address(this)));

        // Transfer back what has not been sold.
        if (sellTokenBalance > 0) {
            sellTokenAddress.safeTransferFrom(address(this), auctioneer, sellTokenBalance);
        }

        // Callback to auction house for administrative purposes.
        if (address(auctionHouse) != address(0)) {
            auctionHouse.closeFungible(
                address(sellTokenAddress),
                address(buyTokenAddress),
                initialAmount - sellTokenBalance,
                lowestSellPrice
            );
        }
    }

    /// VIEWS
    /// @dev Get price per token.
    function getPrice() public view override returns (uint256) {
        if (block.timestamp <= startTimestamp) {
            return maxPrice;
        }

        // Guard against timestamps *very* far into the future and/or long durations.
        // TODO: Intended? Should an item that can no longer be sold return `minPrice`?
        if (block.timestamp > startTimestamp.add(duration)) {
            return minPrice;
        }

        // Safe subtraction. Already guarded in the constructor.
        uint256 priceRange = maxPrice - minPrice;

        // Safe subtraction. Already guarded by `block.timestamp > startTimestamp.add(duration)`.
        uint256 elapsedTime = block.timestamp - startTimestamp;
        uint256 priceReduction = priceRange.mul(elapsedTime).div(duration);

        // Already guarded, because elapsedTime cannot exceed duration.
        return maxPrice - priceReduction;
    }

    /// @dev Check whether auction is still active, i.e. still running and with tokens remaining.
    function isActive() public view override returns (bool) {
        return
            startTimestamp <= block.timestamp &&
            // Safe addition: the constructor already checks for an overflow.
            block.timestamp < startTimestamp + duration &&
            sellTokenAddress.balanceOf(address(this)) > 0;
    }

    function getPriceInBuyTokens(uint256 amount) internal view returns (uint256) {
        return amount.mul(getPrice());
    }
}
