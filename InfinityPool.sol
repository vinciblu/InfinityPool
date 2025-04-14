pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract InfinityPool is Initializable, ERC20Upgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, OwnableUpgradeable {
    using SafeMath for uint256;

    uint256 public constant FEE_PERCENTAGE = 3;
    uint256 public constant INITIAL_PRICE = 2 wei;
    uint256 public constant PRICE_INCREASE_RATE = 2 wei;
    address public feeCollector;

    event Minted(address indexed user, uint256 ethAmount, uint256 tokenAmount);
    event Burned(address indexed user, uint256 tokenAmount, uint256 ethAmount);


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _feeCollector) public initializer {
        __ERC20_init("Infinity Pool", "∞");
        __ReentrancyGuard_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        require(_feeCollector != address(0), "Invalid fee collector address");
        feeCollector = _feeCollector;
    }

    function decimals() public pure override returns (uint8) {
        return 4;
    }

    function mint() public payable nonReentrant {
        // CHECKS
        require(msg.value > 0, "Must send ETH to mint");
        
        // Calculate values
        uint256 fee = msg.value.mul(FEE_PERCENTAGE).div(100);
        uint256 afterFeeAmount = msg.value.sub(fee);
        uint256 tokenAmount = calculateAmount(afterFeeAmount);
        require(tokenAmount > 0, "Amount too small");
        
        // Store caller
        address caller = msg.sender;
        
        // EFFECTS - mint tokens first
        _mint(caller, tokenAmount);
        
        // Emit event
        emit Minted(caller, msg.value, tokenAmount);
        
        // INTERACTIONS - external calls last
        (bool success, ) = payable(feeCollector).call{value: fee}("");
        require(success, "Fee transfer failed");
    }

    function burn(uint256 _sellAmount) public nonReentrant returns (uint256) {
        // CHECKS
        require(_sellAmount > 0, "Must burn a positive amount");
        require(balanceOf(msg.sender) >= _sellAmount, "Insufficient balance");
        
        uint256 contractBalance = address(this).balance;
        require(contractBalance > 0, "Contract has no balance");
        
        // Calculate values
        uint256 ethAmount = calculateCost(_sellAmount);
        uint256 fee = ethAmount.mul(FEE_PERCENTAGE).div(100);
        uint256 afterFeeAmount = ethAmount.sub(fee);
        
        uint256 tokensToBurn = _sellAmount;
        
        // If contract doesn't have enough ETH, adjust amounts
        if (contractBalance < ethAmount) {
            ethAmount = contractBalance;
            fee = ethAmount.mul(FEE_PERCENTAGE).div(100);
            afterFeeAmount = ethAmount.sub(fee);
            tokensToBurn = calculateAmount(afterFeeAmount);
            require(tokensToBurn > 0, "Resulting amount too small");
            require(tokensToBurn <= _sellAmount, "Calculation error");
        }
        
        // Store caller address
        address payable caller = payable(msg.sender);
        
        // EFFECTS - burn tokens first
        _burn(caller, tokensToBurn);
        
        // Emit event
        emit Burned(caller, tokensToBurn, ethAmount);
        
        // INTERACTIONS - external calls last
        if (fee > 0) {
            (bool feeSuccess, ) = payable(feeCollector).call{value: fee}("");
            require(feeSuccess, "Fee transfer failed");
        }
        
        (bool success, ) = caller.call{value: afterFeeAmount}("");
        require(success, "Transfer failed");
        
        return afterFeeAmount;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal override {
        // Skip fee if sender or recipient is the fee collector to avoid double fees
        if (sender == feeCollector || recipient == feeCollector) {
            super._transfer(sender, recipient, amount);
            return;
        }
        
        uint256 fee = amount.mul(FEE_PERCENTAGE).div(100);
        uint256 afterFeeAmount = amount.sub(fee);

        super._transfer(sender, recipient, afterFeeAmount);
        super._transfer(sender, feeCollector, fee);
    }

    function calculateAmount(uint256 _depositAmount) public view returns (uint256) {
        uint256 currentSupply = totalSupply();
        
        // For a linear bonding curve where price = initial_price + (supply * increase_rate)
        // The amount of tokens for a given ETH input can be calculated using the quadratic formula
        // ETH = tokens * (initial_price + (currentSupply + tokens/2) * increase_rate)
        
        // Simplified quadratic equation: ax^2 + bx - c = 0
        // Where:
        // a = PRICE_INCREASE_RATE / 2
        // b = INITIAL_PRICE + (currentSupply * PRICE_INCREASE_RATE)
        // c = _depositAmount * 100 (accounting for decimals)
        
        uint256 a = PRICE_INCREASE_RATE.div(2);
        uint256 b = INITIAL_PRICE.add(currentSupply.mul(PRICE_INCREASE_RATE));
        uint256 c = _depositAmount.mul(100); // Multiply by 100 for 2 decimals
        
        // Quadratic formula: (-b + sqrt(b^2 + 4ac)) / (2a)
        uint256 sqrtTerm = sqrt(b.mul(b).add(a.mul(c).mul(4)));
        uint256 tokenAmount = sqrtTerm.sub(b).div(a.mul(2));
        
        return tokenAmount;
    }

     function calculateCost(uint256 _sellAmount) public view returns (uint256) {
        uint256 currentSupply = totalSupply();
        require(currentSupply >= _sellAmount, "Not enough supply");
        
        // For selling, we need to calculate the area under the curve from
        // (currentSupply - _sellAmount) to currentSupply
        
        uint256 endPrice = INITIAL_PRICE.add(currentSupply.mul(PRICE_INCREASE_RATE));
        uint256 startPrice = INITIAL_PRICE.add((currentSupply.sub(_sellAmount)).mul(PRICE_INCREASE_RATE));
        
        // Area = _sellAmount * (startPrice + endPrice) / 2
        uint256 totalCost = _sellAmount.mul(startPrice.add(endPrice)).div(2);
        
        // Adjust for decimals
        return totalCost.div(100);
    }

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        
        return y;
    }

    function getCurrentPrice() public view returns (uint256) {
        return INITIAL_PRICE.add(PRICE_INCREASE_RATE.mul(totalSupply()));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
