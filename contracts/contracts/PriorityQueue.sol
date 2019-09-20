pragma solidity ^0.5.8;

import "./Bytes.sol";

contract PriorityQueue {

    // MARK: - CONSTANTS

    // Operation fields bytes lengths
    uint8 TOKEN_BYTES = 2; // token id
    uint8 AMOUNT_BYTES = 16; // token amount
    uint8 ETH_ADDR_BYTES = 20; // ethereum address
    uint8 FEE_BYTES = 2; // fee
    uint8 ACC_NUM_BYTES = 3; // franklin account id
    uint8 NONCE_BYTES = 4; // franklin nonce

    // Franklin chain address length
    uint8 constant PUBKEY_HASH_LEN = 20;
    // Signature (for example full exit signature) length
    uint8 constant SIGNATURE_LEN = 64;
    // Public key length
    uint8 constant PUBKEY_LEN = 32;
    // Fee coefficient for priority request transaction
    uint256 constant FEE_COEFF = 4;
    // Base gas cost for transaction
    uint256 constant BASE_GAS = 21000;
    // Chunks per block; each chunk has 8 bytes of public data
    uint256 constant BLOCK_SIZE = 14;
    // Max amount of any token must fit into uint128
    uint256 constant MAX_VALUE = 2 ** 112 - 1;
    // Expiration delta for priority request to be satisfied (in ETH blocks)
    uint256 constant PRIORITY_EXPIRATION = 250; // About 1 hour
    // ETH blocks verification expectation
    uint256 constant EXPECT_VERIFICATION_IN = 8 * 60 * 100;
    // Max number of unverified blocks. To make sure that all reverted blocks can be copied under block gas limit!
    uint256 constant MAX_UNVERIFIED_BLOCKS = 4 * 60 * 100;

    // Operations lengths

    uint256 constant NOOP_LENGTH = 1 * 8; // noop
    uint256 constant DEPOSIT_LENGTH = 6 * 8; // deposit
    uint256 constant TRANSFER_TO_NEW_LENGTH = 5 * 8; // transfer
    uint256 constant PARTIAL_EXIT_LENGTH = 6 * 8; // partial exit
    uint256 constant CLOSE_ACCOUNT_LENGTH = 1 * 8; // close account
    uint256 constant TRANSFER_LENGTH = 2 * 8; // transfer
    uint256 constant FULL_EXIT_LENGTH = 18 * 8; // full exit

    // New priority request event
    // Emitted when a request is placed into mapping
    // Params:
    // - opType - operation type
    // - pubData - operation data
    // - expirationBlock - the number of Ethereum block when request becomes expired
    // - fee - validators' fee
    event NewPriorityRequest(
        uint64 serialId,
        OpType opType,
        bytes pubData,
        uint256 expirationBlock,
        uint256 fee
    );

    // Priority Queue

    // Types of franklin operations in blocks
    enum OpType {
        Noop,
        Deposit,
        TransferToNew,
        PartialExit,
        CloseAccount,
        Transfer,
        FullExit
    }

    // Priority Operation contains operation type, its data, expiration block, and fee
    struct PriorityOperation {
        OpType opType;
        bytes pubData;
        uint256 expirationBlock;
        uint256 fee;
    }

    // Priority Requests mapping (request id - operation)
    // Contains op type, pubdata, fee and expiration block of unsatisfied requests.
    // Numbers are in order of requests receiving
    mapping(uint64 => PriorityOperation) public priorityRequests;
    // First priority request id
    uint64 public firstPriorityRequestId;
    // Total number of requests
    uint64 public totalOpenPriorityRequests;
    // Total number of committed requests
    uint64 public totalCommittedPriorityRequests;

    // Calculate expiration block for request, store this request and emit NewPriorityRequest event
    // Params:
    // - _opType - priority request type
    // - _fee - validators' fee
    // - _pubData - request data
    function addPriorityRequest(
        OpType _opType,
        uint256 _fee,
        bytes calldata _pubData
    ) external {
        // Expiration block is: current block number + priority expiration delta
        uint256 expirationBlock = block.number + PRIORITY_EXPIRATION;

        priorityRequests[firstPriorityRequestId+totalOpenPriorityRequests] = PriorityOperation({
            opType: _opType,
            pubData: _pubData,
            expirationBlock: expirationBlock,
            fee: _fee
        });

        emit NewPriorityRequest(
            firstPriorityRequestId+totalOpenPriorityRequests,
            _opType,
            _pubData,
            expirationBlock,
            _fee
        );

        totalOpenPriorityRequests++;
    }

    // Collects a fee from provided requests number for the validator, store it on her
    // balance to withdraw in Ether and delete this requests
    // Params:
    // - _number - the number of requests
    function collectValidatorsFeeAndDeleteRequests(uint64 _number) external returns (uint256) {
        require(
            _number <= totalOpenPriorityRequests,
            "fcs11"
        ); // fcs11 - number is heigher than total priority requests number

        uint256 totalFee = 0;
        for (uint64 i = firstPriorityRequestId; i < firstPriorityRequestId + _number; i++) {
            totalFee += priorityRequests[i].fee;
            delete priorityRequests[i];
        }
        totalOpenPriorityRequests -= _number;
        firstPriorityRequestId += _number;
        totalCommittedPriorityRequests -= _number;

        return totalFee;
    }

    // Accrues users balances from priority requests,
    // if this request contains a Deposit operation
    // WARNING: Only for Exodus mode
    function cancelOutstandingDepositsForExodusMode() external view returns (
        address[] memory owners,
        uint16[] memory tokens,
        uint128[] memory amounts
    ) {
        uint64 counter = 0;
        for (uint64 i = firstPriorityRequestId; i < firstPriorityRequestId + totalOpenPriorityRequests; i++) {
            if (priorityRequests[i].opType == OpType.Deposit) {
                bytes memory pubData = priorityRequests[i].pubData;
                bytes memory owner = new bytes(ETH_ADDR_BYTES);
                for (uint8 j = 0; j < ETH_ADDR_BYTES; ++j) {
                    owner[j] = pubData[j];
                }
                bytes memory token = new bytes(TOKEN_BYTES);
                for (uint8 j = 0; j < TOKEN_BYTES; j++) {
                    token[j] = pubData[ETH_ADDR_BYTES + j];
                }
                bytes memory amount = new bytes(AMOUNT_BYTES);
                for (uint8 j = 0; j < AMOUNT_BYTES; ++j) {
                    amount[j] = pubData[ETH_ADDR_BYTES + TOKEN_BYTES + j];
                }
                owners[counter] = Bytes.bytesToAddress(owner);
                tokens[counter] = Bytes.bytesToUInt16(token);
                amounts[counter] = Bytes.bytesToUInt128(amount);
                counter++;
            }
        }
    }

    // Compares operation from the block with corresponding priority requests' operation
    // Params:
    // - _opType - operation type
    // - _pubData - operation pub data
    // - _id - operation number
    function isPriorityOpValid(OpType _opType, bytes memory _pubData, uint64 _id) internal view returns (bool) {
        uint64 _priorityRequestId = _id + firstPriorityRequestId + totalCommittedPriorityRequests;
        bytes memory priorityPubData;
        bytes memory onchainPubData;
        if (_opType == OpType.Deposit && priorityRequests[_priorityRequestId].opType == OpType.Deposit) {
            priorityPubData = Bytes.slice(priorityRequests[_priorityRequestId].pubData, ETH_ADDR_BYTES, PUBKEY_HASH_LEN + AMOUNT_BYTES + TOKEN_BYTES);
            onchainPubData = _pubData;
        } else if (_opType == OpType.FullExit && priorityRequests[_priorityRequestId].opType == OpType.FullExit) {
            priorityPubData = Bytes.slice(priorityRequests[_priorityRequestId].pubData, 0, PUBKEY_LEN + ETH_ADDR_BYTES + TOKEN_BYTES + NONCE_BYTES + SIGNATURE_LEN);
            onchainPubData = Bytes.slice(_pubData, ACC_NUM_BYTES, PUBKEY_LEN + ETH_ADDR_BYTES + TOKEN_BYTES + NONCE_BYTES + SIGNATURE_LEN);
        } else {
            revert("fid11"); // fid11 - wrong operation
        }
        return (priorityPubData.length > 0) &&
            (keccak256(onchainPubData) == keccak256(priorityPubData));
    }

    function validateNumberOfRequests(uint64 _number) external view {
        require(
            _number <= totalOpenPriorityRequests-totalCommittedPriorityRequests,
            "fvs11"
        ); // fvs11 - too much priority requests
    }

    function increaseCommittedRequestsNumber(uint64 _number) external {
        totalCommittedPriorityRequests += _number;
    }

    function decreaseCommittedRequestsNumber(uint64 _number) external {
        totalCommittedPriorityRequests -= _number;
    }

    // Checks if Exodus mode must be entered. If true - cancels outstanding deposits and emits ExodusMode event.
    // Returns bool flag that is true if the Exodus mode must be entered.
    // Exodus mode must be entered in case of current ethereum block number is higher than the oldest
    // of existed priority requests expiration block number.
    function triggerExodusIfNeeded() external view returns (bool) {
        if (
            block.number >= priorityRequests[firstPriorityRequestId].expirationBlock &&
            priorityRequests[firstPriorityRequestId].expirationBlock != 0
        ) {
            return true;
        } else {
            return false;
        }
    }
}