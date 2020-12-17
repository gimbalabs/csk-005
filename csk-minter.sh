#!/usr/bin/env bash
set -e
#set -x

# This script creates, signs, and submits a transaction that creates some new
# tokens that will be sent to the same origin wallet used to pay for the fees.

NETWORK_MAGIC=3
SOURCE_ADDRESS=$(cat /opt/cardano/cnode/priv/wallet/csk005/base.addr)
DESTINATION_ADDRESS=${SOURCE_ADDRESS}
PAYMENT_SKEY="/opt/cardano/cnode/priv/wallet/csk005/payment.skey"
TOKEN_NAME=SPAM$$token
TOKEN_AMOUNT=1

# 1. Create a policy for our token
mkdir -p ${TOKEN_NAME}
POLICY_SCRIPT=${TOKEN_NAME}/policy.script
POLICY_VKEY=${TOKEN_NAME}/policy.vkey
POLICY_SKEY=${TOKEN_NAME}/policy.skey
cardano-cli address key-gen \
            --verification-key-file ${POLICY_VKEY} \
            --signing-key-file ${POLICY_SKEY}
KEYHASH=$(cardano-cli address key-hash --payment-verification-key-file ${POLICY_VKEY})
cat > ${POLICY_SCRIPT} <<EOF
{
  "keyHash": "${KEYHASH}",
  "type": "sig"
}
EOF
POLICY_ID=$(cardano-cli transaction policyid --script-file ${POLICY_SCRIPT})

# 2. Extract protocol parameters (needed for fee calculations)
cardano-cli query protocol-parameters \
            --testnet-magic ${NETWORK_MAGIC} \
            --mary-era \
            --out-file /tmp/protparams.json

# 3. Get UTXOs from our wallet
IN_UTXO=$(cardano-cli query utxo \
                      --mary-era \
                      --testnet-magic ${NETWORK_MAGIC} \
                      --address ${SOURCE_ADDRESS} | grep -v "^ \|^-" | awk '{print "--tx-in "$1"#"$2}' | xargs)
UTXO_COUNT=$(cardano-cli query utxo \
                         --mary-era \
                         --testnet-magic ${NETWORK_MAGIC} \
                         --address ${SOURCE_ADDRESS} | grep -v "^ \|^-" | wc -l)
# 4. Calculate different tokens balances from our UTXOs
## 4.1 Cleanup tmp
rm -f /tmp/balance*
## 4.2 Query our address again and save output into a file
cardano-cli query utxo \
            --mary-era \
            --testnet-magic ${NETWORK_MAGIC} \
            --address ${SOURCE_ADDRESS} | grep -v "^ \|^-" | sed 's| + |\n|g' | sed 's|.* \([0-9].*lovelace\)|\1|g' > /tmp/balances
## 4.3 Sum different tokens balances and save them on different files
awk '{print $2}' /tmp/balances | uniq | while read token; do grep ${token} /tmp/balances | awk '{s+=$1} END {print s}' > /tmp/balance.${token}; done
OTHER_COINS=$(for balance_file in $(ls -1 /tmp/balance.* | grep -v lovelace); do BALANCE=$(cat ${balance_file}); TOKEN=$(echo $balance_file | sed 's|/tmp/balance.||g'); echo +${BALANCE} ${TOKEN}; done | xargs)

# 5. Calculate fees for the transaction
# 5.1 Build a draft transaction to calculate fees
cardano-cli transaction build-raw \
            --mary-era \
            --fee 0 \
            ${IN_UTXO} \
            --tx-out="${DESTINATION_ADDRESS}+$(cat /tmp/balance.lovelace) lovelace${OTHER_COINS}+${TOKEN_AMOUNT} ${POLICY_ID}.${TOKEN_NAME}" \
            --mint="${TOKEN_AMOUNT} ${POLICY_ID}.${TOKEN_NAME}" \
            --out-file ${TOKEN_NAME}.txbody-draft

# 5.2 Calculate actual fees for transaction
MIN_FEE=$(cardano-cli transaction calculate-min-fee \
                      --tx-body-file ${TOKEN_NAME}.txbody-draft \
                      --tx-in-count ${UTXO_COUNT} \
                      --tx-out-count 1 \
                      --witness-count 1 \
                      --byron-witness-count 0 \
                      --protocol-params-file /tmp/protparams.json | awk '{print $1}')

# 6. Build actual transaction including correct fees
cardano-cli transaction build-raw \
            --mary-era \
            --fee ${MIN_FEE} \
	    ${IN_UTXO} \
	    --tx-out="${DESTINATION_ADDRESS}+$(( $(cat /tmp/balance.lovelace) - ${MIN_FEE} )) lovelace${OTHER_COINS}+${TOKEN_AMOUNT} ${POLICY_ID}.${TOKEN_NAME}" \
            --mint="${TOKEN_AMOUNT} ${POLICY_ID}.${TOKEN_NAME}" \
            --out-file ${TOKEN_NAME}.txbody-ok-fee

# 7. Sign the transaction
cardano-cli transaction sign \
            --testnet-magic ${NETWORK_MAGIC} \
            --signing-key-file ${PAYMENT_SKEY} \
            --signing-key-file ${POLICY_SKEY} \
            --script-file ${POLICY_SCRIPT} \
            --tx-body-file  ${TOKEN_NAME}.txbody-ok-fee \
            --out-file      ${TOKEN_NAME}.tx.signed

# 8. Submit the transaction to the blockchain
cardano-cli transaction submit \
	    --tx-file ${TOKEN_NAME}.tx.signed \
	    --testnet-magic ${NETWORK_MAGIC}
