<!-- verify smart contract after deployment -->
forge verify-contract \
  --chain base-sepolia \
  --watch \
  0xYourDeployedAddress \
  src/MyToken.sol:MyToken \
  --constructor-args $(cast abi-encode "constructor(string,string,uint256)" "Token" "TKN" 18) \
  --verifier etherscan \
  --etherscan-api-key $ETHERSCAN_API_KEY