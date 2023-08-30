// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract GiverHCF is Ownable {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    /// @notice ERC20 token for rewards
    IERC20 private immutable _token;

    /// @notice The number of blocks between readjustments of the mining difficulty
    uint256 private constant _BLOCKS_PER_READJUSTMENT = 24;
    /// @notice The minimum target value for mining difficulty
    uint256 private constant _MINIMUM_TARGET = 2 ** 16;
    /// @notice The maximum target value for mining difficulty
    uint256 private constant _MAXIMUM_TARGET = 2 ** 220;
    /// @notice The number of tokens to be rewarded for each successful mine
    uint256 private constant _REWARD_AMOUNT = 93e18; // 93 tokens
    /// @notice The number of tokens to be burned when burning mechanism is activated
    uint256 private constant _BURN_AMOUNT = 30e18; // 30 tokens


    /// @notice The target number of blocks per difficulty period
    uint256 private constant _TARGET_BLOCKS_PER_DIFF_PERIOD =
        _BLOCKS_PER_READJUSTMENT * 900;

    /// @notice Difficulty denominator
    uint256 private constant _DIFFICULTY_DENOMINATOR = 2000;

    /// @notice Counter for the current epoch of mining rewards
    Counters.Counter private _epochCounter;

    /// @notice The most recent difficulty period start block number
    uint256 private _latestDifficultyPeriodStarted;
    /// @notice The current mining difficulty target value
    uint256 private _miningTarget;
    /// @notice The total number of tokens that have been minted so far
    uint256 private _tokensMinted;
    /// @notice The timestamp of the last mining epoch
    uint256 private _lastMiningEpochTimestamp;
    /// @notice The current mining challenge number
    bytes32 private _challengeNumber;
    /// @notice Number of blocks per difficulty readjustment
    uint256 private _blocksPerReadjustment;
    /// @notice Difficulty denominator
    uint256 private _difficultyDenominator;
    /// @notice Target blocks number per difficulty period
    uint256 private _targetBlocksPerDiffPeriod;

    /// @notice Is burning mechanism enabled
    bool private _burningEnabled;
    /// @notice The block number at which the burning mechanism starts
    uint256 private _burnBlockStart;
    /// @notice The maximum detected difficulty on the network
    uint256 private _maximumDifficulty;




    constructor(IERC20 token) {
        _token = token;
        _miningTarget = _MAXIMUM_TARGET;
        _latestDifficultyPeriodStarted = block.number;

        _blocksPerReadjustment = _BLOCKS_PER_READJUSTMENT;
        _difficultyDenominator = _DIFFICULTY_DENOMINATOR;
        _targetBlocksPerDiffPeriod = _TARGET_BLOCKS_PER_DIFF_PERIOD;
        
        // Make sure that burning is disabled
        _burningEnabled = false;
        _burnBlockStart = type(uint256).max;


        _startNewMiningEpoch();
    }

    /////////////////////
    //      Errors     //
    /////////////////////

    /// @notice When the provided message for signature verification is incorrect
    error IncorrectMessage();
    /// @notice When the hash value of the solution is too high
    error HighHash();
    /// @notice When a duplicate solution is submitted
    error DuplicateSolution();
    /// @notice When the balance in the contract is insufficient to reward the miner
    error InsufficientBalance();

    /////////////////////
    //      Events     //
    /////////////////////

    /// @notice Emitted when the mining target difficulty is set or adjusted
    event MiningTargetSet(uint256 target);
    /// @notice Emitted in case of successful payment of the rewards
    event Claim(
        address indexed to,
        uint256 rewardAmount,
        uint256 currentEpoch,
        bytes32 newChallengeNumber
    );
    /// @notice Emitted when the number of blocks per readjustment is set or modified
    event BlocksPerReadjustmentSet(uint256 blocks);
    /// @notice Emitted when the difficulty denominator is set or modified
    event DifficultyDenominatorSet(uint256 denominator);
    /// @notice Emitted when the target blocks number per difficulty adjustment period is set or modified
    event TargetBlocksPerDiffPeriodSet(uint256 targetBlocks);
    /// @notice Emitted when burning block start number is set or modified
    event BurnBlockStartSet(uint256 blockNumber);
    /// @notice Emitted when burning is enabled
    event BurningEnabled();
    /// @notice Emitted when burning is disabled
    event BurningDisabled();


    /////////////////////
    //      Mining     //
    /////////////////////

    /**
     * @notice Starts a new mining epoch by incrementing the epoch counter
     * and retrieving a new challenge number
     * @dev The difficulty of mining is readjusted every 24 epochs.
     * The challenge number is set to the block hash of the previous block
     */
    function _startNewMiningEpoch() internal {
        _epochCounter.increment();

        if (_epochCounter.current() % _blocksPerReadjustment == 0) {
            _reAdjustDifficulty();
        }

        _lastMiningEpochTimestamp = block.timestamp;
        _challengeNumber = blockhash(block.number - 1);
    }

    /**
     * @notice Re-adjusts the mining difficulty
     *
     * @dev This function is called periodically to adjust the mining difficulty
     * based on the number of blocks that have been mined since
     * the last difficulty adjustment period.
     * If the number of mined blocks is less than the target number of blocks,
     * the mining difficulty is decreased.
     * Otherwise, it is increased. The new mining difficulty is then bounded
     * by a minimum and a maximum value.
     */
    function _reAdjustDifficulty() internal {
        // Calculate the number of blocks that have passed since the last difficulty period
        uint256 blocksSinceLastDifficultyPeriod = block.number -
            _latestDifficultyPeriodStarted;

        // If the number of blocks is less than the target number of blocks,
        // decrease the mining target
        if (
            blocksSinceLastDifficultyPeriod <
            _targetBlocksPerDiffPeriod
        ) {
            // Calculate the percentage of the actual number of blocks mined above the target
            uint256 excessBlockPct = (_targetBlocksPerDiffPeriod *
                100) / blocksSinceLastDifficultyPeriod;

            // Calculate the percentage increase in difficulty
            uint256 excessBlockPctExtra = (excessBlockPct - 100);
            if (excessBlockPctExtra > 1000) {
                excessBlockPctExtra = 1000;
            }

            // Decrease the mining target proportionally to the percentage of excess blocks
            _miningTarget =
                _miningTarget -
                (_miningTarget / _difficultyDenominator) *
                excessBlockPctExtra;
        } else {
            // If the number of blocks is greater than or equal to the target number of blocks,
            // increase the mining target
            // Calculate the percentage that the actual number of blocks mined is below the target
            uint256 shortageBlockPct = (blocksSinceLastDifficultyPeriod *
                100) / _targetBlocksPerDiffPeriod;

            // Calculate the percentage decrease in difficulty
            uint256 shortageBlockPctExtra = shortageBlockPct - 100;
            if (shortageBlockPctExtra > 1000) {
                shortageBlockPctExtra = 1000;
            }

            // Increase the mining target based on the percentage decrease in difficulty
            _miningTarget =
                _miningTarget +
                (_miningTarget / _difficultyDenominator) *
                shortageBlockPctExtra;
        }

        // Update the latest difficulty period start block number
        _latestDifficultyPeriodStarted = block.number;

        // Ensure that the mining target does not fall below the minimum value
        if (_miningTarget < _MINIMUM_TARGET) {
            _miningTarget = _MINIMUM_TARGET;
        }

        // Ensure that the mining target does not exceed the maximum value
        if (_miningTarget > _MAXIMUM_TARGET) {
            _miningTarget = _MAXIMUM_TARGET;
        }




        // Burning mechanism

        // Check if the block number is above burning start block
        if (block.number>_burnBlockStart) {

            // Calculate current difficulty
            uint256 difficulty=_MAXIMUM_TARGET/_miningTarget;

            if(difficulty>_maximumDifficulty) {
                _maximumDifficulty=difficulty;  // Update _maximumDifficulty

                // If burning is active disable it
                if(_burningEnabled==true) {
                    _burningEnabled=false;
                    
                    emit BurningDisabled();
                }
            }

            if(_burningEnabled==false) {
                // Check if the difficulty has got below 30% of the maximum detected difficulty
                uint256 burningDifficulty = _maximumDifficulty-(_maximumDifficulty/100)*30;

                if(difficulty<burningDifficulty) {
                    _burningEnabled=true;   // Activate burning

                    emit BurningEnabled();
                }
            }
        }

    }

    ///  Setters and Getters

    

    /**
     * @notice Set the mining target value, which is used to determine the difficulty of mining
     * @param target The new mining target value to be set
     * @dev Emit a MiningTargetSet event with the new target value
     */
    function setMiningTarget(uint256 target) external onlyOwner {
        _miningTarget = target;

        emit MiningTargetSet(target);
    }

    /// @notice Returns the current mining target
    function getMiningTarget() external view returns (uint256) {
        return _miningTarget;
    }



    /**
     * @notice Set number of blocks per readjustment to control how frequently the difficulty will be recalculated
     * @param blocks The new blocks per readjustment value to be set
     * @dev Emit a BlocksPerReadjustmentSet event with the new blocks value
     */
    function setBlocksPerReadjustment(uint256 blocks) external onlyOwner {
        _blocksPerReadjustment = blocks;

        emit BlocksPerReadjustmentSet(blocks);
    }

    /// @notice Returns the current number of blocks per readjustment
    function getBlocksPerReadjustment() external view returns (uint256) {
        return _blocksPerReadjustment;
    }

    /**
     * @notice Set difficulty denominator value to control how much will it change during each adjustment period
     * @param denominator The new denominator value to be set
     * @dev Emit a DifficultyDenominatorSet event with the new denominator value
     */
    function setDifficultyDenominator(uint256 denominator) external onlyOwner {
        _difficultyDenominator = denominator;

        emit DifficultyDenominatorSet(denominator);
    }

    /// @notice Returns the current value of difficulty denominator
    function getDifficultyDenominator() external view returns (uint256) {
        return _difficultyDenominator;
    }

    /**
     * @notice Set target number of blocks per difficulty period to control how frequently a new block should be found
     * @param targetBlocks The new target number of blocks value to be set
     * @dev Emit a DifficultyDenominatorSet event with the new denominator value
     */
    function setTargetBlocksPerDiffPeriod(uint256 targetBlocks) external onlyOwner {
        _targetBlocksPerDiffPeriod = targetBlocks;

        emit TargetBlocksPerDiffPeriodSet(targetBlocks);
    }

    /// @notice Returns the current value of difficulty denominator
    function getTargetBlocksPerDiffPeriod() external view returns (uint256) {
        return _targetBlocksPerDiffPeriod;
    }

    /**
     * @notice Set the polygon block number when a burning mechanism will be activated
     * @param blockNumber The polygon block number
     * @dev Emit a BurnBlockStartSet event with the block number value
     */
    function setBurnBlockStart(uint256 blockNumber) external onlyOwner {
        _burnBlockStart = blockNumber;

        emit BurnBlockStartSet(blockNumber);
    }

    /// @notice Returns the current value of difficulty denominator
    function getBurnBlockStart() external view returns (uint256) {
        return _burnBlockStart;
    }


    /**
     * @notice Set burningEnabled variable as true
     * @dev Emit a BurningEnabled event
     */
    function setBurningEnabled() external onlyOwner {
        _burningEnabled = true;

        emit BurningEnabled();
    }

    /**
     * @notice Set burningEnabled variable as false
     * @dev Emit a BurningDisabled event
     */
    function setBurningDisabled() external onlyOwner {
        _burningEnabled = false;

        emit BurningDisabled();
    }

    /// @notice Returns the current value of _burningEnabled variable
    function getBurningEnabled() external view returns (bool) {
        return _burningEnabled;
    }


    /// @notice Returns the mining difficulty,
    /// @dev Which is the ratio of the maximum target to the current mining target
    function getMiningDifficulty() external view returns (uint256) {
        return _MAXIMUM_TARGET / _miningTarget;
    }

    /// @notice Returns the block number when the latest difficulty period started
    function getLatestDifficultyPeriodStart() external view returns (uint256) {
        return _latestDifficultyPeriodStarted;
    }

    /// @notice Returns the current epoch number
    function getCurrentEpoch() external view returns (uint256) {
        return _epochCounter.current();
    }

    /// @notice Returns the current challenge number
    function getChallengeNumber() external view returns (bytes32) {
        return _challengeNumber;
    }

    /// @notice Returns the mining reward amount
    function getMiningReward() external pure returns (uint256) {
        return _REWARD_AMOUNT;
    }

    /// @notice Returns the total number of tokens minted so far
    function getMintedTokensAmount() external view returns (uint256) {
        return _tokensMinted;
    }

    /// @notice Returns the maximum detected difficulty once the burning is activated
    function getMaximumDifficulty() external view returns (uint256) {
        return _maximumDifficulty;
    }

    /// @notice Returns the current target and challenge number (API endpoint optimization)
    function getMiningTargetAndChallengeNumber() external view returns (uint256, bytes32) {
        return (_miningTarget, _challengeNumber);
    }



    /////////////////////
    //      Claim      //
    /////////////////////

    /**
     * @notice Allows a miner to claim a reward for successfully mining a solution
     * @param msgHash The hash of the message signed by the miner
     * @param v The recovery id of the signature
     * @param r The r value of the signature
     * @param s The s value of the signature
     * @dev Reverts if the provided message hash does not match the prefixed hash message
     * Reverts if the hash of the solution is greater than the current mining target
     * Reverts if the solution has already been used to claim a reward
     * Reverts if there are insufficient tokens to award the miner with the reward amount
     * Emits a Claim event on success
     */
    function claim(
        bytes32 msgHash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (bool success) {
        // Check that the signed message is the expected message
        if (_prefixedHashMessage() != msgHash) {
            revert IncorrectMessage();
        }

        // Calculate the digest from the signed message, challenge number,
        // and the address of the sender
        bytes32 digest = _digest(msgHash, _challengeNumber, v, r, s);

        // Check that the digest is less than the current mining target
        if (uint256(digest) > _miningTarget) {
            revert HighHash();
        }

        uint256 duration = block.timestamp - _lastMiningEpochTimestamp;
        // Check if the duration since the last mining epoch is zero,
        // indicating that a solution has already been claimed for this epoch
        if (duration == 0) {
            revert DuplicateSolution();
        }
        

        _tokensMinted += _REWARD_AMOUNT;
        
        uint256 contract_balance = _token.balanceOf(address(this));

        if (_REWARD_AMOUNT > contract_balance) {
            revert InsufficientBalance();
        }

        _startNewMiningEpoch();

        // Transfer the reward amount to the miner
        _token.safeTransfer(msg.sender, _REWARD_AMOUNT);

        // Burn tokens if burning enabled
        if(_burningEnabled==true) {
          if(contract_balance-_REWARD_AMOUNT-_BURN_AMOUNT > 0) {
            ERC20Burnable(address(_token)).burn(_BURN_AMOUNT);
          }
        }

        emit Claim(
            msg.sender,
            _REWARD_AMOUNT,
            _epochCounter.current(),
            _challengeNumber
        );

        return true;
    }

    /**
     * @notice Verify a mining solution for a given challenge number and test target
     * @param challengeNumber The challenge number for which to verify the solution
     * @param testTarget The target to compare the solution hash
     * @param msgHash The hash of the signed message
     * @param v The recovery id of the signature
     * @param r The r value of the signature
     * @param s The s value of the signature
     */
    function verifyMiningSolution(
        bytes32 challengeNumber,
        uint256 testTarget,
        bytes32 msgHash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (bool success) {
        if (_prefixedHashMessage() != msgHash) {
            revert IncorrectMessage();
        }

        bytes32 digest = _digest(msgHash, challengeNumber, v, r, s);

        if (uint256(digest) > testTarget) {
            return false;
        }

        return true;
    }

    /**
     * @notice Computes the digest used for proof-of-work validation
     * @param msgHash The hash of the signed message
     * @param challengeNumber The current challenge number
     * @param v The recovery id of the signature
     * @param r The r value of the signature
     * @param s The s value of the signature
     */
    function _digest(
        bytes32 msgHash,
        bytes32 challengeNumber,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view returns (bytes32 digest) {
        address powAddress = ecrecover(msgHash, v, r, s);

        digest = keccak256(
            abi.encodePacked(powAddress, msg.sender, challengeNumber)
        );
    }

    /**
     * @notice Computes and returns the keccak256 hash of a prefixed message
     * to be signed using the EIP-712 standard
     */
    function _prefixedHashMessage()
        internal
        view
        returns (bytes32 prefixedHashMessage)
    {
        bytes memory prefix = "\x19Ethereum Signed Message:\n72";

        prefixedHashMessage = keccak256(
            abi.encodePacked(prefix, msg.sender, _challengeNumber)
        );
    }

    /// Service function

    /**
     * @notice Transfer a specified amount of an ERC20 token held by the contract
     * to the owner's address
     * @param token The address of the ERC20 token to transfer
     * @param amount The amount of the ERC20 token to transfer
     */
    function transferERC20(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(owner(), amount);
    }

    /**
     * @notice Burn a specified amount of an ERC20 token held by the contract
     * @param amount The amount of the ERC20 token to burn
     */
    function burnTokens(uint256 amount) external onlyOwner {
        ERC20Burnable(address(_token)).burn(amount);
    }
}
