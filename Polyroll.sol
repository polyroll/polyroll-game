// SPDX-License-Identifier: MIT

import "https://github.com/smartcontractkit/chainlink/blob/0964ca290565587963cc4ad8f770274f5e0d9e9d/evm-contracts/src/v0.6/VRFConsumerBase.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";

pragma solidity 0.6.12;

// Polyroll is the contract that governs the 3 games at Polyroll.org: coin flip, dice roll, and polyroll.
contract Polyroll is VRFConsumerBase, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Chainlink VRF related parameters
    address constant LINK_TOKEN = 0xb0897686c545045aFc77CF20eC7A532E3120E0F1;
    address public VRF_COORDINATOR = 0x3d2341ADb2D31f1c5530cDC622016af293177AE0;
    bytes32 public KEY_HASH = 0xf86195cf7690c55907b2b611ebb7343a6f649bff128701cc542f0569e2c549da;
    uint public chainlinkFee = 100000000000000; // 0.0001 LINK

    // Each bet is deducted 1% in favor of the house
    uint constant HOUSE_EDGE_PERCENT = 1;

    // Modulo is the number of equiprobable outcomes in a game:
    //  2 for coin flip
    //  6 for dice roll
    //  6*6 = 36 for double dice
    //  100 for polyroll
    uint constant MAX_MODULO = 100;

    // Modulos below MAX_MASK_MODULO are checked against a bit mask, allowing betting on specific outcomes. 
    // For example in a dice roll (modolo = 6), 
    // 000001 mask means betting on 1. 000001 converted from binary to decimal becomes 1.
    // 101000 mask means betting on 4 and 6. 101000 converted from binary to decimal becomes 40.
    // The specific value is dictated by the fact that 256-bit intermediate
    // multiplication result allows implementing population count efficiently
    // for numbers that are up to 42 bits, and 40 is the highest multiple of
    // eight below 42.
    uint constant MAX_MASK_MODULO = 40;

     // This is a check on bet mask overflow. Maximum mask is equivalent to number of possible binary outcomes for maximum modulo.
    uint constant MAX_BET_MASK = 2 ** MAX_MASK_MODULO;

    // These are constants taht make O(1) population count in placeBet possible.
    uint constant POPCNT_MULT = 0x0000000000002000000000100000000008000000000400000000020000000001;
    uint constant POPCNT_MASK = 0x0001041041041041041041041041041041041041041041041041041041041041;
    uint constant POPCNT_MODULO = 0x3F;

    // In addition to house edge, wealth tax is added every time the bet amount exceeds a multiple of a threshold.
    // For example, if wealthTaxIncrementThreshold = 3000 ether,
    // A bet amount of 3000 ether will have a wealth tax of 1% in addition to house edge.
    // A bet amount of 6000 ether will have a wealth tax of 2% in addition to house edge.
    uint public wealthTaxIncrementThreshold = 3000 ether;
    uint public wealthTaxIncrementPercent = 1;

    // The minimum and maximum bets.
    uint public minBetAmount = 1 ether;
    uint public maxBetAmount = 20 ether;

    // Adjustable max bet profit. Used to cap bets against dynamic odds.
    uint public maxProfit = 3000000 ether;

    // Funds that are locked in potentially winning bets. Prevents contract from committing to new bets that it cannot pay out.
    uint public lockedInBets;

    // Info of each bet.
    struct Bet {
        // Wager amount in wei.
        uint amount;
        // Modulo of a game.
        uint8 modulo;
        // Number of winning outcomes, used to compute winning payment (* modulo/rollUnder),
        // and used instead of mask for games with modulo > MAX_MASK_MODULO.
        uint8 rollUnder;
        // Bit mask representing winning bet outcomes (see MAX_MASK_MODULO comment).
        uint40 mask;
        // Block number of placeBet tx.
        uint placeBlockNumber;
        // Address of a gambler, used to pay out winning bets.
        address payable gambler;
        // Status of bet settlement.
        bool isSettled;
        // Outcome of bet.
        uint outcome;
        // Win amount.
        uint winAmount;
        // Random number used to settle bet.
        uint randomNumber;
    }

    // List of bets
    Bet[] public bets;

    // Store Number of bets
    uint public betsLength;

    // Mapping requestId returned by Chainlink VRF to bet Id
    mapping(bytes32 => uint) public betMap;

    // Events
    event BetPlaced(uint indexed betId, address indexed gambler);
    event BetSettled(uint indexed betId, address indexed gambler, uint winAmount);
    event BetRefunded(uint indexed betId, address indexed gambler);

    // Constructor. Using Chainlink VRFConsumerBase constructor.
    constructor() VRFConsumerBase(VRF_COORDINATOR, LINK_TOKEN) public {}

    // Fallback payable function deliberately left empty. It is used to top up the bank roll.
    fallback() external payable {}
    receive() external payable {}

    // See ETH balance.
    function balance() external view returns (uint) {
        return address(this).balance;
    }

    // Update Chainlink fee
    function setChainlinkFee(uint _chainlinkFee) external onlyOwner {
        chainlinkFee = _chainlinkFee;
    }

    // Set min bet amount. minBetAmount should be large enough such that its house edge fee can cover the settlement gas fee and oracle fee.
    function setMinBetAmount(uint _minBetAmount) external onlyOwner {
        minBetAmount = _minBetAmount;
    }

    // Set max bet amount.
    function setMaxBetAmount(uint _maxBetAmount) external onlyOwner {
        require (_maxBetAmount < 300000 ether, "maxBetAmount must be a sane number");
        maxBetAmount = _maxBetAmount;
    }

    // Set max bet reward. Setting this to zero effectively disables betting.
    function setMaxProfit(uint _maxProfit) external onlyOwner {
        require (_maxProfit < 300000 ether, "maxProfit must be a sane number");
        maxProfit = _maxProfit;
    }

    // Set wealth tax percentage to be added to house edge percent. Setting this to zero effectively disables wealth tax.
    function setWealthTaxIncrementPercent(uint _wealthTaxIncrementPercent) external onlyOwner {
        wealthTaxIncrementPercent = _wealthTaxIncrementPercent;
    }

    // Set threshold to trigger wealth tax.
    function setWealthTaxIncrementThreshold(uint _wealthTaxIncrementThreshold) external onlyOwner {
        wealthTaxIncrementThreshold = _wealthTaxIncrementThreshold;
    }

    // Owner can withdraw funds not exceeding contract balance minus potential win prizes
    function withdrawFunds(address payable beneficiary, uint withdrawAmount) external onlyOwner {
        require (withdrawAmount <= address(this).balance, "Withdrawal amount larger than balance.");
        require (withdrawAmount <= address(this).balance - lockedInBets, "Withdrawal amount larger than balance minus lockedInBets");
        beneficiary.transfer(withdrawAmount);
    }

    // Place bet
    function placeBet(uint betMask, uint modulo) external payable nonReentrant {

        // Validate input data.
        uint amount = msg.value;
        require(LINK.balanceOf(address(this)) >= chainlinkFee, "Not enough LINK in contract.");
        require (modulo > 1 && modulo <= MAX_MODULO, "Modulo should be within range.");
        require (amount >= minBetAmount && amount <= maxBetAmount, "Bet amount should be within range.");
        require (betMask > 0 && betMask < MAX_BET_MASK, "Mask should be within range.");

        uint rollUnder;
        uint mask;

        if (modulo <= MAX_MASK_MODULO) {
            // Small modulo games can specify exact bet outcomes via bit mask.
            // rollUnder is a number of 1 bits in this mask (population count).
            // This magic looking formula is an efficient way to compute population
            // count on EVM for numbers below 2**40. 
            rollUnder = ((betMask * POPCNT_MULT) & POPCNT_MASK) % POPCNT_MODULO;
            mask = betMask;
        } else {
            // Larger modulos games specify the right edge of half-open interval of winning bet outcomes.
            require (betMask > 0 && betMask <= modulo, "High modulo range, betMask larger than modulo.");
            rollUnder = betMask;
        }

        // Winning amount.
        uint possibleWinAmount = getDiceWinAmount(amount, modulo, rollUnder);

        // Enforce max profit limit.
        require (possibleWinAmount <= amount + maxProfit, "maxProfit limit violation.");

        // Check whether contract has enough funds to accept this bet.
        require (lockedInBets + possibleWinAmount <= address(this).balance, "Unable to accept bet due to insufficient funds");

        // Update lock funds.
        lockedInBets += possibleWinAmount;

        // Store bet in bet list
        bets.push(Bet(
            {
                amount: amount,
                modulo: uint8(modulo),
                rollUnder: uint8(rollUnder),
                mask: uint40(mask),
                placeBlockNumber: block.number,
                gambler: msg.sender,
                isSettled: false,
                outcome: 0,
                winAmount: 0,
                randomNumber: 0
            }
        ));

        // Request random number from Chainlink VRF. Store requestId for validation checks later.
        bytes32 requestId = requestRandomness(KEY_HASH, chainlinkFee, betsLength);

        // Map requestId to bet ID
        betMap[requestId] = betsLength;

        // Record bet in event logs
        emit BetPlaced(betsLength, msg.sender);

        betsLength++;
    }

    // Get the expected win amount after house edge is subtracted.
    function getDiceWinAmount(uint amount, uint modulo, uint rollUnder) private view returns (uint winAmount) {
        require (0 < rollUnder && rollUnder <= modulo, "Win probability out of range.");
        uint houseEdge = amount * (HOUSE_EDGE_PERCENT + getWealthTax(amount)) / 100;
        winAmount = (amount - houseEdge) * modulo / rollUnder;
    }

    // Get wealth tax 
    function getWealthTax(uint amount) private view returns (uint wealthTax) {
        wealthTax = amount / wealthTaxIncrementThreshold * wealthTaxIncrementPercent;
    }

    // Callback function called by VRF coordinator
    function fulfillRandomness(bytes32 requestId, uint randomness) internal override {
        settleBet(requestId, randomness);
    }

    // Settle bet. Function can only be called by fulfillRandomness function, which in turn can only be called by Chainlink VRF.
    function settleBet(bytes32 requestId, uint randomNumber) internal nonReentrant {
        
        uint betId = betMap[requestId];
        Bet storage bet = bets[betId];
        uint amount = bet.amount;
        
        // Validation check
        require (amount > 0, "Bet does not exist."); // Check that bet exists
        require(bet.isSettled == false, "Bet is settled already"); // Check that bet is not settled yet

        // Fetch bet parameters into local variables (to save gas).
        uint modulo = bet.modulo;
        uint rollUnder = bet.rollUnder;
        address payable gambler = bet.gambler;

        // Do a roll by taking a modulo of random number.
        uint outcome = randomNumber % modulo;

        // Win amount if gambler wins this bet
        uint possibleWinAmount = getDiceWinAmount(amount, modulo, rollUnder);

        // Actual win amount by gambler
        uint winAmount = 0;

        // Determine dice outcome.
        if (modulo <= MAX_MASK_MODULO) {
            // For small modulo games, check the outcome against a bit mask.
            if ((2 ** outcome) & bet.mask != 0) {
                winAmount = possibleWinAmount;
            }
        } else {
            // For larger modulos, check inclusion into half-open interval.
            if (outcome < rollUnder) {
                winAmount = possibleWinAmount;
            }
        }
        
        // Record bet settlement in event log.
        emit BetSettled(betId, gambler, winAmount);

        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        lockedInBets -= possibleWinAmount;

        // Update bet records
        bet.isSettled = true;
        bet.winAmount = winAmount;
        bet.randomNumber = randomNumber;
        bet.outcome = outcome;

        // Send win amount to gambler.
        gambler.transfer(winAmount == 0 ? 1 wei : winAmount);
    }


    // Return the bet if it was not settled.
    // In case you ever find yourself in a situation like this, just contact Polyroll support.
    // However, nothing precludes you from calling this method yourself.
    function refundBet(uint betId) external nonReentrant payable {
        
        Bet storage bet = bets[betId];
        uint amount = bet.amount;

        // Validation check
        require (amount > 0, "Bet does not exist."); // Check that bet exists
        require (bet.isSettled == false, "Bet is settled already."); // Check that bet is still open

        // Bet can only be refunded after 600 blocks (~20 minutes).
        require (block.number > bet.placeBlockNumber + 600, "Wait 600 blocks after placing bet before requesting refund.");

        uint possibleWinAmount = getDiceWinAmount(amount, bet.modulo, bet.rollUnder);

        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        lockedInBets -= possibleWinAmount;

        // Update bet records
        bet.isSettled = true;
        bet.winAmount = amount;

        // Send the refund.
        bet.gambler.transfer(amount);

        // Record refund in event logs
        emit BetRefunded(betId, bet.gambler);
    }

    // Withdraw LINK and other ERC20 tokens sent here by mistake
    function withdrawTokens(address token_address) external onlyOwner {
        IERC20(token_address).safeTransfer(owner(), IERC20(token_address).balanceOf(address(this)));
    }
}
