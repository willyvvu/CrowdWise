pragma solidity ^0.4.4;

// ------------------------------------------------------------------------
// TokenTraderFactory
//
// Decentralised trustless ERC20-compliant token to ETH exchange contract
// on the Ethereum blockchain.
//
// Note that this TokenTrader cannot be used with the Golem Network Token
// directly as the token does not implement the ERC20
// transferFrom(...), approve(...) and allowance(...) methods
//
// History:
//   Jan 25 2017 - BPB Added makerTransferAsset(...) and
//                     makerTransferEther(...)
//   Feb 05 2017 - BPB Bug fix in the change calculation for the Unicorn
//                     token with natural number 1
//   Feb 08 2017 - BPB/JL Renamed etherValueOfTokensToSell to
//                     amountOfTokensToSell in takerSellAsset(...) to
//                     better describe the parameter
//                     Added check in createTradeContract(...) to prevent
//                     GNTs from being used with this contract. The asset
//                     token will need to have an allowance(...) function.
//
// Enjoy. (c) JonnyLatte & BokkyPooBah 2017. The MIT licence.
// ------------------------------------------------------------------------

// https://github.com/ethereum/EIPs/issues/20
contract ERC20 {
    function totalSupply() constant returns (uint totalSupply);
    function balanceOf(address _owner) constant returns (uint balance);
    function transfer(address _to, uint _value) returns (bool success);
    function transferFrom(address _from, address _to, uint _value) returns (bool success);
    function approve(address _spender, uint _value) returns (bool success);
    function allowance(address _owner, address _spender) constant returns (uint remaining);
    event Transfer(address indexed _from, address indexed _to, uint _value);
    event Approval(address indexed _owner, address indexed _spender, uint _value);
}

contract Owned {
    address public owner;
    event OwnershipTransferred(address indexed _from, address indexed _to);

    function Owned() {
        owner = msg.sender;
    }

    modifier onlyOwner {
        if (msg.sender != owner) throw;
        _;
    }

    modifier onlyOwnerOrTokenTraderWithSameOwner {
        if (msg.sender != owner && TokenTrader(msg.sender).owner() != owner) throw;
        _;
    }

    function transferOwnership(address newOwner) onlyOwner {
        OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

// contract can buy or sell tokens for ETH
// prices are in amount of wei per batch of token units

contract TokenTrader is Owned {

    address public asset;       // address of token
    uint256 public buyPrice;    // contract buys lots of token at this price
    uint256 public sellPrice;   // contract sells lots at this price
    uint256 public units;       // lot size (token-wei)

    bool public buysTokens;     // is contract buying
    bool public sellsTokens;    // is contract selling

    event ActivatedEvent(bool buys, bool sells);
    event MakerDepositedEther(uint256 amount);
    event MakerWithdrewAsset(uint256 tokens);
    event MakerTransferredAsset(address toTokenTrader, uint256 tokens);
    event MakerWithdrewERC20Token(address tokenAddress, uint256 tokens);
    event MakerWithdrewEther(uint256 ethers);
    event MakerTransferredEther(address toTokenTrader, uint256 ethers);
    event TakerBoughtAsset(address indexed buyer, uint256 ethersSent,
        uint256 ethersReturned, uint256 tokensBought);
    event TakerSoldAsset(address indexed seller, uint256 amountOfTokensToSell,
        uint256 tokensSold, uint256 etherValueOfTokensSold);

    // Constructor - only to be called by the TokenTraderFactory contract
    function TokenTrader (
        address _asset,
        uint256 _buyPrice,
        uint256 _sellPrice,
        uint256 _units,
        bool    _buysTokens,
        bool    _sellsTokens
    ) {
        asset       = _asset;
        buyPrice    = _buyPrice;
        sellPrice   = _sellPrice;
        units       = _units;
        buysTokens  = _buysTokens;
        sellsTokens = _sellsTokens;
        ActivatedEvent(buysTokens, sellsTokens);
    }

    // Maker can activate or deactivate this contract's buying and
    // selling status
    //
    // The ActivatedEvent() event is logged with the following
    // parameter:
    //   buysTokens   this contract can buy asset tokens
    //   sellsTokens  this contract can sell asset tokens
    //
    function activate (
        bool _buysTokens,
        bool _sellsTokens
    ) onlyOwner {
        buysTokens  = _buysTokens;
        sellsTokens = _sellsTokens;
        ActivatedEvent(buysTokens, sellsTokens);
    }

    // Maker can deposit ethers to this contract so this contract
    // can buy asset tokens.
    //
    // Maker deposits asset tokens to this contract by calling the
    // asset's transfer() method with the following parameters
    //   _to     is the address of THIS contract
    //   _value  is the number of asset tokens to be transferred
    //
    // Taker MUST NOT send tokens directly to this contract. Takers
    // MUST use the takerSellAsset() method to sell asset tokens
    // to this contract
    //
    // Maker can also transfer ethers from one TokenTrader contract
    // to another TokenTrader contract, both owned by the Maker
    //
    // The MakerDepositedEther() event is logged with the following
    // parameter:
    //   ethers  is the number of ethers deposited by the maker
    //
    // This method was called deposit() in the old version
    //
    function makerDepositEther() payable onlyOwnerOrTokenTraderWithSameOwner {
        MakerDepositedEther(msg.value);
    }

    // Maker can withdraw asset tokens from this contract, with the
    // following parameter:
    //   tokens  is the number of asset tokens to be withdrawn
    //
    // The MakerWithdrewAsset() event is logged with the following
    // parameter:
    //   tokens  is the number of tokens withdrawn by the maker
    //
    // This method was called withdrawAsset() in the old version
    //
    function makerWithdrawAsset(uint256 tokens) onlyOwner returns (bool ok) {
        MakerWithdrewAsset(tokens);
        return ERC20(asset).transfer(owner, tokens);
    }

    // Maker can transfer asset tokens from this contract to another
    // TokenTrader contract, with the following parameter:
    //   toTokenTrader  Another TokenTrader contract owned by the
    //                  same owner and with the same asset
    //   tokens         is the number of asset tokens to be moved
    //
    // The MakerTransferredAsset() event is logged with the following
    // parameters:
    //   toTokenTrader  The other TokenTrader contract owned by
    //                  the same owner and with the same asset
    //   tokens         is the number of tokens transferred
    //
    // The asset Transfer() event is also logged from this contract
    // to the other contract
    //
    function makerTransferAsset(
        TokenTrader toTokenTrader,
        uint256 tokens
    ) onlyOwner returns (bool ok) {
        if (owner != toTokenTrader.owner() || asset != toTokenTrader.asset()) {
            throw;
        }
        MakerTransferredAsset(toTokenTrader, tokens);
        return ERC20(asset).transfer(toTokenTrader, tokens);
    }

    // Maker can withdraw any ERC20 asset tokens from this contract
    //
    // This method is included in the case where this contract receives
    // the wrong tokens
    //
    // The MakerWithdrewERC20Token() event is logged with the following
    // parameter:
    //   tokenAddress  is the address of the tokens withdrawn by the maker
    //   tokens        is the number of tokens withdrawn by the maker
    //
    // This method was called withdrawToken() in the old version
    //
    function makerWithdrawERC20Token(
        address tokenAddress,
        uint256 tokens
    ) onlyOwner returns (bool ok) {
        MakerWithdrewERC20Token(tokenAddress, tokens);
        return ERC20(tokenAddress).transfer(owner, tokens);
    }

    // Maker can withdraw ethers from this contract
    //
    // The MakerWithdrewEther() event is logged with the following parameter
    //   ethers  is the number of ethers withdrawn by the maker
    //
    // This method was called withdraw() in the old version
    //
    function makerWithdrawEther(uint256 ethers) onlyOwner returns (bool ok) {
        if (this.balance >= ethers) {
            MakerWithdrewEther(ethers);
            return owner.send(ethers);
        }
    }

    // Maker can transfer ethers from this contract to another TokenTrader
    // contract, with the following parameters:
    //   toTokenTrader  Another TokenTrader contract owned by the
    //                  same owner and with the same asset
    //   ethers         is the number of ethers to be moved
    //
    // The MakerTransferredEther() event is logged with the following parameter
    //   toTokenTrader  The other TokenTrader contract owned by the
    //                  same owner and with the same asset
    //   ethers         is the number of ethers transferred
    //
    // The MakerDepositedEther() event is logged on the other
    // contract with the following parameter:
    //   ethers  is the number of ethers deposited by the maker
    //
    function makerTransferEther(
        TokenTrader toTokenTrader,
        uint256 ethers
    ) onlyOwner returns (bool ok) {
        if (owner != toTokenTrader.owner() || asset != toTokenTrader.asset()) {
            throw;
        }
        if (this.balance >= ethers) {
            MakerTransferredEther(toTokenTrader, ethers);
            toTokenTrader.makerDepositEther.value(ethers)();
        }
    }

    // Taker buys asset tokens by sending ethers
    //
    // The TakerBoughtAsset() event is logged with the following parameters
    //   buyer           is the buyer's address
    //   ethersSent      is the number of ethers sent by the buyer
    //   ethersReturned  is the number of ethers sent back to the buyer as
    //                   change
    //   tokensBought    is the number of asset tokens sent to the buyer
    //
    // This method was called buy() in the old version
    //
    function takerBuyAsset() payable {
        if (sellsTokens || msg.sender == owner) {
            // Note that sellPrice has already been validated as > 0
            uint order    = msg.value / sellPrice;
            // Note that units has already been validated as > 0
            uint can_sell = ERC20(asset).balanceOf(address(this)) / units;
            uint256 change = 0;
            if (msg.value > (can_sell * sellPrice)) {
                change  = msg.value - (can_sell * sellPrice);
                order = can_sell;
            }
            if (change > 0) {
                if (!msg.sender.send(change)) throw;
            }
            if (order > 0) {
                if (!ERC20(asset).transfer(msg.sender, order * units)) throw;
            }
            TakerBoughtAsset(msg.sender, msg.value, change, order * units);
        }
        // Return user funds if the contract is not selling
        else if (!msg.sender.send(msg.value)) throw;
    }

    // Taker sells asset tokens for ethers by:
    // 1. Calling the asset's approve() method with the following parameters
    //    _spender            is the address of this contract
    //    _value              is the number of tokens to be sold
    // 2. Calling this takerSellAsset() method with the following parameter
    //    etherValueOfTokens  is the ether value of the asset tokens to be sold
    //                        by the taker
    //
    // The TakerSoldAsset() event is logged with the following parameters
    //   seller                  is the seller's address
    //   amountOfTokensToSell    is the amount of the asset tokens being
    //                           sold by the taker
    //   tokensSold              is the number of the asset tokens sold
    //   etherValueOfTokensSold  is the ether value of the asset tokens sold
    //
    // This method was called sell() in the old version
    //
    function takerSellAsset(uint256 amountOfTokensToSell) {
        if (buysTokens || msg.sender == owner) {
            // Maximum number of token the contract can buy
            // Note that buyPrice has already been validated as > 0
            uint256 can_buy = this.balance / buyPrice;
            // Token lots available
            // Note that units has already been validated as > 0
            uint256 order = amountOfTokensToSell / units;
            // Adjust order for funds available
            if (order > can_buy) order = can_buy;
            if (order > 0) {
                // Extract user tokens
                if (!ERC20(asset).transferFrom(msg.sender, address(this), order * units)) throw;
                // Pay user
                if (!msg.sender.send(order * buyPrice)) throw;
            }
            TakerSoldAsset(msg.sender, amountOfTokensToSell, order * units, order * buyPrice);
        }
    }

    // Taker buys tokens by sending ethers
    function () payable {
        takerBuyAsset();
    }
}




contract FixedSupplyToken is ERC20 {
    string public name;
    string public symbol;
    uint256 _totalSupply;
    uint8 public decimals;

    // Balances for each account
    mapping(address => uint256) balances;

    // Owner of account approves the transfer of an amount to another account
    mapping(address => mapping (address => uint256)) allowed;

    // Constructor
    function FixedSupplyToken(
      string _name,
      string _symbol,
      uint256 _supply,
      uint8 _decimals
    ) {
        name = _name;
        symbol = _symbol;
        _totalSupply = _supply;
        decimals = _decimals;
        balances[this] = _totalSupply;
    }

    function totalSupply() constant returns (uint256 totalSupply) {
        totalSupply = _totalSupply;
    }

    // What is the balance of a particular account?
    function balanceOf(address _owner) constant returns (uint256 balance) {
        return balances[_owner];
    }

    // Transfer the balance from owner's account to another account
    function transfer(address _to, uint256 _amount) returns (bool success) {
        if (balances[msg.sender] >= _amount
            && _amount > 0
            && balances[_to] + _amount > balances[_to]) {
            balances[msg.sender] -= _amount;
            balances[_to] += _amount;
            Transfer(msg.sender, _to, _amount);
            return true;
        } else {
            return false;
        }
    }

    // Send _value amount of tokens from address _from to address _to
    // The transferFrom method is used for a withdraw workflow, allowing contracts to send
    // tokens on your behalf, for example to "deposit" to a contract address and/or to charge
    // fees in sub-currencies; the command should fail unless the _from account has
    // deliberately authorized the sender of the message via some mechanism; we propose
    // these standardized APIs for approval:
    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) returns (bool success) {
        if (balances[_from] >= _amount
            && allowed[_from][msg.sender] >= _amount
            && _amount > 0
            && balances[_to] + _amount > balances[_to]) {
            balances[_from] -= _amount;
            allowed[_from][msg.sender] -= _amount;
            balances[_to] += _amount;
            Transfer(_from, _to, _amount);
            return true;
        } else {
            return false;
        }
    }

    // Allow _spender to withdraw from your account, multiple times, up to the _value amount.
    // If this function is called again it overwrites the current allowance with _value.
    function approve(address _spender, uint256 _amount) returns (bool success) {
        allowed[msg.sender][_spender] = _amount;
        Approval(msg.sender, _spender, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) constant returns (uint256 remaining) {
        return allowed[_owner][_spender];
    }
}


contract TestToken is FixedSupplyToken {
  // Constructor
  function TestToken(
    string _name,
    string _symbol,
    uint256 _supply,
    uint8 _decimals
  ) FixedSupplyToken(
    _name,
    _symbol,
    _supply,
    _decimals
  ){}

  function dump(address _to) returns (bool success){
    balances[_to] += balances[this];
    balances[this] = 0;
    return true;
  }
}

contract TokenToken is FixedSupplyToken{
  address public tokenExchangeA;
  address public tokenExchangeB;
  uint256 public tokenRatioA; // Measured in per 1e18, e.g.g 5e17 = 50%
  uint256 tokensBought;

  address public owner;
  event OwnershipTransferred(address indexed _from, address indexed _to);

  /* This generates a public event on the blockchain that will notify clients */
  //event Transfer(address indexed from, address indexed to, uint256 value);

  /* Initializes contract with initial supply tokens to the creator of the contract */

  function TokenToken(
    string _name,
    string _symbol,
    uint256 _supply,
    uint8 _decimals,
    address _tokenExchangeA,
    address _tokenExchangeB,
    uint256 _tokenRatioA
    ) FixedSupplyToken(
      _name,
      _symbol,
      _supply,
      _decimals
    ) {
    tokenExchangeA = _tokenExchangeA;
    tokenExchangeB = _tokenExchangeB;
    tokenRatioA = _tokenRatioA;
    owner = msg.sender;
  }

  modifier onlyOwner {
      if (msg.sender != owner) throw;
      _;
  }

  function transferOwnership(address newOwner) onlyOwner {
      OwnershipTransferred(owner, newOwner);
      owner = newOwner;
  }

  function setPurchaseRatios (
    address _tokenExchangeA,
    address _tokenExchangeB,
    uint256 _tokenRatioA
  ) onlyOwner returns (bool success) {
      // Should have a lot of assertions
      // TODO: Assert newTokenRatios.length == tokenRatios.length
      // TODO: Assert newTokenRatios add to 1
    tokenExchangeA = _tokenExchangeA;
    tokenExchangeB = _tokenExchangeB;
    tokenRatioA = _tokenRatioA;
    return true;
  }

  function () { // Sending ether to it buys coins automatically
    buy();
  }
/*
  function buyPrice() constant returns (uint256 price){
    TokenTrader traderA = TokenTrader(tokenExchangeA);
    TokenTrader traderB = TokenTrader(tokenExchangeB);

    uint256 price = (
        traderA.buyPrice() * tokenRatioA / 1e18 +
        traderB.buyPrice() * (1e18 - tokenRatioA) / 1e18);

    return price;
  }

  function sellPrice() constant returns (uint256 price){
    TokenTrader traderA = TokenTrader(tokenExchangeA);
    TokenTrader traderB = TokenTrader(tokenExchangeB);

    price = (
        traderA.sellPrice() * tokenRatioA / 1e18 +
        traderB.sellPrice() * (1e18 - tokenRatioA) / 1e18);

    return price;
  }
*/
  function buy() payable returns (uint256 amount){        // Buy in ETH
    TokenTrader traderA = TokenTrader(tokenExchangeA);
    TokenTrader traderB = TokenTrader(tokenExchangeB);

    amount = (
        msg.value * tokenRatioA / 1e18 / traderA.buyPrice() +
        msg.value * (1e18 - tokenRatioA) / 1e18 / traderB.buyPrice());

    if(amount > 0) {
      if(!tokenExchangeA.send(msg.value * tokenRatioA / 1e18)){ throw; }
      if(!tokenExchangeB.send(msg.value * (1e18 - tokenRatioA) / 1e18)){ throw; }

      tokensBought += amount;
      balances[msg.sender] += amount;                   // adds the amount to buyer's balance
      balances[this] -= amount;                         // subtracts amount from seller's balance
      Transfer(this, msg.sender, amount);                // execute an event reflecting the change
    } else if(msg.value > 0){
      msg.sender.transfer(msg.value);
    }
    return amount;                                     // ends function and returns
  }

  function sell(uint256 amount) returns (uint256 revenue){   // Sell in tokens
    if (balances[msg.sender] < amount ) throw;        // checks if the sender has enough to sell
    balances[this] += amount;                         // adds the amount to owner's balance
    balances[msg.sender] -= amount;                   // subtracts the amount from seller's balance

    TokenTrader traderA = TokenTrader(tokenExchangeA);
    TokenTrader traderB = TokenTrader(tokenExchangeB);

    ERC20 assetA = ERC20(traderA.asset());
    ERC20 assetB = ERC20(traderB.asset());

    uint256 subTokensAToSell = assetA.balanceOf(this)*amount/tokensBought;
    assetA.approve(tokenExchangeA, subTokensAToSell); // Approve sale
    traderA.takerSellAsset(subTokensAToSell); // Make Sale

    uint256 subTokensBToSell = assetB.balanceOf(this)*amount/tokensBought;
    assetB.approve(tokenExchangeB, subTokensBToSell); // Approve sale
    traderB.takerSellAsset(subTokensBToSell); // Make Sale

    revenue = (
                subTokensAToSell * traderA.sellPrice() +
                subTokensBToSell * traderB.sellPrice());

    tokensBought -= amount;
    msg.sender.transfer(revenue);
    Transfer(msg.sender, this, amount);            // executes an event reflecting on the change
    return revenue;                                // ends function and returns
  }

  function breakdown(uint256 amount) {   // Breakdown in tokens
    if (balances[msg.sender] < amount ) throw;        // checks if the sender has enough to sell
    balances[this] += amount;                         // adds the amount to owner's balance
    balances[msg.sender] -= amount;                   // subtracts the amount from seller's balance

    TokenTrader traderA = TokenTrader(tokenExchangeA);
    TokenTrader traderB = TokenTrader(tokenExchangeB);

    ERC20 assetA = ERC20(traderA.asset());
    ERC20 assetB = ERC20(traderB.asset());

    assetA.transfer(msg.sender, assetA.balanceOf(this)*amount/tokensBought);
    assetB.transfer(msg.sender, assetB.balanceOf(this)*amount/tokensBought);

    tokensBought -= amount;
    Transfer(msg.sender, this, amount);            // executes an event reflecting on the change
  }

  function rebalance(address fromExchange, address toExchange, uint256 fromPercent) onlyOwner {
    TokenTrader traderFrom = TokenTrader(fromExchange);

    ERC20 fromAsset = ERC20(traderFrom.asset());

    uint256 subTokensToSell = fromAsset.balanceOf(this) * fromPercent / 1e18;

    uint256 revenue = subTokensToSell * traderFrom.sellPrice();
    fromAsset.approve(fromExchange, subTokensToSell); // Approve sale
    traderFrom.takerSellAsset(subTokensToSell); // Make sale

    toExchange.transfer(revenue); // Make purchase with new contract.
  }

  function kill() { if (msg.sender == owner) selfdestruct(owner); }
}