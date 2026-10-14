// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Independent test oracle for the canonical source-burn identity.
/// @dev The typehash is fixed here rather than read from the contract under test.
library BurnIdHelper {
    bytes32 internal constant TYPEHASH = keccak256(
        "UtexoBurnId(address bridge,uint256 chainId,address token,uint256 amount,uint256 sourceChainId,bytes32 sourceAddressHash,bytes32 sourceBurnTxId)"
    );

    function derive(
        address bridge,
        uint256 chainId,
        address token,
        uint256 amount,
        uint256 sourceChainId,
        string memory sourceAddress,
        bytes32 sourceBurnTxId
    ) internal pure returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    TYPEHASH,
                    bridge,
                    chainId,
                    token,
                    amount,
                    sourceChainId,
                    keccak256(bytes(sourceAddress)),
                    sourceBurnTxId
                )
            )
        );
    }
}
