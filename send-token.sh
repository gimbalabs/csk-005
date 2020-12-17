#!/usr/bin/env bash

set -e
# set -x

# This script creates, signs, and submits a transaction that creates some new tokens.
# It uses the output of the transaction from update-4.sh.

NETWORK_MAGIC=3
SOURCE_ADDRESS=$(cat ../base.addr)
DESTINATION_ADDRESS=$(cat /opt/cardano/cnode/priv/wallet/csk005/base.addr)
PAYMENT_SKEY=../payment.skey
TOKEN_POLICY=67990188e55b6141bdcfa9958759cb021be22984431eb76f5726d6ae.SPAM9511token
SEND_AMOUNT=1

cardano-cli query protocol-parameters \
    --testnet-magic ${NETWORK_MAGIC} \
    --mary-era \
    --out-file /tmp/protparams.json

IN_UTXO=$(cardano-cli query utxo \
    --mary-era \
    --testnet-magic ${NETWORK_MAGIC} \
    --address ${SOURCE_ADDRESS} | grep -v "^ \|^-" | awk '{print "--tx-in "$1"#"$2}' | xargs)
UTXO_COUNT=$(cardano-cli query utxo \
    --mary-era \
    --testnet-magic ${NETWORK_MAGIC} \
    --address ${SOURCE_ADDRESS} | grep -v "^ \|^-" | wc -l)
# calc balances
rm -f /tmp/balance*
cardano-cli query utxo \
    --mary-era \
    --testnet-magic ${NETWORK_MAGIC} \
    --address ${SOURCE_ADDRESS} | grep -v "^ \|^-" | sed 's| + |\n|g' | sed 's|.* \([0-9].*lovelace\)|\1|g' > /tmp/balances
awk '{print $2}' /tmp/balances | uniq | while read token; do grep ${token} /tmp/balances | awk '{s+=$1} END {print s}' > /tmp/balance.${token}; done
sed -i "s|$(cat /tmp/balance.${TOKEN_POLICY})|$(( $(cat /tmp/balance.${TOKEN_POLICY}) - ${SEND_AMOUNT} ))|g" /tmp/balance.${TOKEN_POLICY}
OTHER_COINS=$(for balance_file in $(ls -1 /tmp/balance.* | grep -v lovelace); do BALANCE=$(cat ${balance_file}); TOKEN=$(echo $balance_file | sed 's|/tmp/balance.||g'); echo +${BALANCE} ${TOKEN}; done | xargs)

cardano-cli transaction build-raw \
            --mary-era \
            --fee 0 \
	    ${IN_UTXO} \
	    --tx-out="${DESTINATION_ADDRESS}+2000000 lovelace+${SEND_AMOUNT} ${TOKEN_POLICY}" \
	    --tx-out="${SOURCE_ADDRESS}+$(cat /tmp/balance.lovelace) lovelace${OTHER_COINS}" \
            --out-file ${TOKEN_NAME}.txbody

ACTUAL_MIN_FEE=$(cardano-cli transaction calculate-min-fee \
    --tx-body-file ${TOKEN_NAME}.txbody \
    --tx-in-count ${UTXO_COUNT} \
    --tx-out-count 1 \
    --witness-count 1 \
    --byron-witness-count 0 \
    --protocol-params-file /tmp/protparams.json | awk '{print $1}')

cardano-cli transaction build-raw \
            --mary-era \
            --fee ${ACTUAL_MIN_FEE} \
	    ${IN_UTXO} \
	    --tx-out="${DESTINATION_ADDRESS}+2000000 lovelace+${SEND_AMOUNT} ${TOKEN_POLICY}" \
	    --tx-out="${SOURCE_ADDRESS}+$(( $(cat /tmp/balance.lovelace) - ${ACTUAL_MIN_FEE} - 2000000)) lovelace${OTHER_COINS}" \
            --out-file ${TOKEN_NAME}.txbody-ok-fee

cardano-cli transaction sign \
            --testnet-magic ${NETWORK_MAGIC} \
            --signing-key-file ${PAYMENT_SKEY} \
            --tx-body-file  ${TOKEN_NAME}.txbody-ok-fee \
            --out-file      ${TOKEN_NAME}.tx.signed

cardano-cli transaction submit --tx-file ${TOKEN_NAME}.tx.signed --testnet-magic ${NETWORK_MAGIC}

